#!/bin/bash
# Single consolidated CEC daemon for the Framework HDMI Expansion Card,
# replacing the previous cec-guard/cec-power/cec-suspend/cec-reassert
# split. That split meant FOUR independent processes (bus-event loop,
# boot-time wake, shutdown cleanup, suspend/resume cleanup) all reading
# and writing the same "are we active source" state at different
# trigger points with no coordination - every bug found on 2026-08-04
# traced back to that shape (state clobbered across restarts, a write
# silently not recognized due to a naming mismatch, an ad-hoc reassert
# accidentally running unrelated shutdown-only side effects). This
# version has exactly one process and one writer.
#
# Responsibilities, all in this one script now:
# - Hold the CEC logical-address claim open for as long as this process
#   lives (claims release when the owning fd closes) and watch the bus.
# - Boot-time wake sequence (was cec-power-on.sh via cec-power.service).
# - Shutdown cleanup via SIGTERM trap (was cec-power-off.sh via
#   cec-power.service's ExecStop - systemd sends SIGTERM before stopping
#   any unit, so a trap here is the direct equivalent with no separate
#   unit needed).
# - Suspend/resume cleanup via a held systemd-logind sleep inhibitor +
#   the PrepareForSleep DBus signal (was cec-suspend.service's
#   Before=sleep.target ordering trick - that pattern only cleanly works
#   for oneshot units; a persistent daemon needs the inhibitor+signal
#   mechanism instead, which is the standard approach other real
#   daemons on this box already use, e.g. NetworkManager/UPower both
#   hold their own sleep delay-inhibitors this same way).
#
# The Framework HDMI Expansion Card fully disconnects and re-enumerates
# at the USB level every time downstream HDMI HPD drops (confirmed via
# kernel logs: "USB disconnect" + ucsi GET_CABLE_PROPERTY failures, not
# just a CEC-level state change) - this happens on essentially every
# TV/AVR power-cycle, so recovering from it fast and without losing
# state is the normal case, not an edge case.
set -uo pipefail
DEV=/dev/cec0
STATE_DIR=/run/cec-guard
STATE_FILE="$STATE_DIR/we-are-active"
CONTROLLER_MAC=C8:3F:26:91:BF:58
mkdir -p "$STATE_DIR"
# Deliberately NOT clearing STATE_FILE here: /run is tmpfs and is already
# empty on a genuine cold boot, so this is a no-op there. State now only
# ever changes in response to real bus events or a confirmed claim.

log() { logger -t cec-daemon "$1"; }

# File-based, not a shell variable: hold/release get called both from the
# top-level script AND from inside the busctl-monitor pipeline below,
# which runs in its own subshell (piped commands always do) - subshells
# don't share variable mutations with their parent, so a plain variable
# here silently desyncs and leaks an orphaned systemd-inhibit process on
# the very first suspend/resume cycle (confirmed live 2026-08-04). Same
# fix shape as STATE_FILE.
INHIBIT_PID_FILE="$STATE_DIR/inhibit-pid"

hold_inhibitor() {
  systemd-inhibit --what=sleep --mode=delay --who="cec-daemon" \
    --why="CEC standby broadcast + controller disconnect before suspend" \
    sleep infinity &
  echo "$!" > "$INHIBIT_PID_FILE"
}

release_inhibitor() {
  if [ -f "$INHIBIT_PID_FILE" ]; then
    kill "$(cat "$INHIBIT_PID_FILE")" 2>/dev/null
    rm -f "$INHIBIT_PID_FILE"
  fi
}

pre_sleep_cleanup() {
  # Same action for both real suspend (via PrepareForSleep) and shutdown
  # (via SIGTERM) - "we are about to stop being on the bus" either way.
  bluetoothctl disconnect "$CONTROLLER_MAC" >/dev/null 2>&1
  if [ -f "$STATE_FILE" ]; then
    log "we were active source - broadcasting standby"
    # --to 15 (broadcast) is required: cec-ctl refuses to send --standby
    # at all without an explicit destination.
    cec-ctl -d "$DEV" --to 15 --standby --no-reply >/dev/null 2>&1
  else
    log "we were NOT recognized as active source - skipping standby broadcast"
  fi
}

do_wake_sequence() {
  local my_phys
  my_phys=$(cec-ctl -d "$DEV" -x -s 2>/dev/null)
  local assert
  assert() {
    cec-ctl -d "$DEV" --to 0 --image-view-on --no-reply >/dev/null 2>&1
    cec-ctl -d "$DEV" --active-source "phys-addr=$my_phys" --no-reply >/dev/null 2>&1
  }
  # Phase 1: keep trying until the TV/AVR are awake enough to register
  # our claim at all - from cold/deep-off this can take many seconds.
  local confirmed=0 i
  for i in $(seq 1 15); do
    assert
    sleep 2
    if [ -f "$STATE_FILE" ]; then
      confirmed=1
      break
    fi
  done
  if [ "$confirmed" -eq 0 ]; then
    log "gave up after 15 attempts - active-source claim never confirmed"
    return
  fi
  # Phase 2: the Apple TV reflexively re-claims active source as part of
  # its own wake sequence - keep re-asserting until we're the LAST
  # claimant once things settle, rather than trusting the first ack.
  for i in $(seq 1 6); do
    sleep 3
    [ -f "$STATE_FILE" ] || assert
  done
  if [ -f "$STATE_FILE" ]; then
    log "active-source claim held after settle window"
  else
    log "lost active-source claim during settle window - reasserting once more"
    assert
  fi
}

on_term() {
  # A plain "systemctl restart cec-daemon" (e.g. deploying a fix) sends
  # the exact same SIGTERM as a real system shutdown - nothing at the
  # signal level distinguishes them. Confirmed live 2026-08-04: an
  # ordinary maintenance restart broadcast a real <Standby> and took
  # down the AVR/Apple TV/TV, since the trap couldn't tell the
  # difference. `systemctl is-system-running` can: it reports
  # "stopping" specifically during an actual system-wide shutdown, and
  # stays "running" for a routine unit restart.
  if [ "$(systemctl is-system-running 2>/dev/null)" = "stopping" ]; then
    pre_sleep_cleanup
  else
    log "SIGTERM received but system is not shutting down (routine restart) - skipping standby broadcast"
  fi
  release_inhibitor
  exit 0
}
trap on_term TERM

# --- DBus sleep/resume monitor (background, own subshell) ---
busctl monitor --match="type='signal',interface='org.freedesktop.login1.Manager',member='PrepareForSleep'" 2>/dev/null | {
  while IFS= read -r line; do
    case "$line" in
      *"BOOLEAN true"*)
        log "PrepareForSleep(true) - about to suspend"
        pre_sleep_cleanup
        release_inhibitor
        ;;
      *"BOOLEAN false"*)
        log "PrepareForSleep(false) - resumed"
        do_wake_sequence &
        hold_inhibitor
        ;;
    esac
  done
} &

hold_inhibitor
do_wake_sequence &

# --- CEC bus monitor loop ---
while true; do
  if [ ! -e "$DEV" ]; then
    sleep 0.2
    continue
  fi

  MY_PHYS=$(cec-ctl -d "$DEV" -x -s 2>/dev/null)

  # Re-entering the loop after a device bounce: if we still believe we
  # were active going in, the bus may have moved on without us during
  # the gap (the Apple TV doesn't wait) - proactively reassert instead
  # of just trusting stale state until the next incoming message.
  if [ -f "$STATE_FILE" ]; then
    cec-ctl -d "$DEV" --to 0 --image-view-on --no-reply >/dev/null 2>&1
    cec-ctl -d "$DEV" --active-source "phys-addr=$MY_PHYS" --no-reply >/dev/null 2>&1
  fi

  cec-ctl -d "$DEV" --playback --osd-name "Framework PC" --monitor -s 2>&1 | {
    ( sleep 1
      if [ ! -f "$STATE_FILE" ]; then
        cec-ctl -d "$DEV" --request-active-source --no-reply >/dev/null 2>&1
      fi
    ) &

    awaiting_new_addr=0

    while IFS= read -r line; do
      case "$line" in
        "Transmitted by Playback Device"*"ACTIVE_SOURCE"*)
          touch "$STATE_FILE"
          ;;
        "Received from"*"ACTIVE_SOURCE"*)
          rm -f "$STATE_FILE"
          ;;
        "Received from"*"ROUTING_CHANGE"*)
          awaiting_new_addr=1
          ;;
        *"new-phys-addr:"*)
          if [ "$awaiting_new_addr" = "1" ]; then
            awaiting_new_addr=0
            new_addr=$(echo "$line" | awk '{print $2}')
            if [ "$new_addr" = "$MY_PHYS" ]; then
              log "Routing changed to us ($MY_PHYS) - marking active"
              touch "$STATE_FILE"
            elif [ -f "$STATE_FILE" ]; then
              log "Routing changed away from us (to $new_addr) - marking inactive"
              rm -f "$STATE_FILE"
            fi
          fi
          ;;
        "Received from TV"*"STANDBY (0x36)"*|"Received from Audio System"*"STANDBY (0x36)"*)
          log "TV/AVR went to standby - suspending to match: $line"
          rm -f "$STATE_FILE"
          systemctl suspend
          ;;
        "Received from"*"STANDBY (0x36)"*)
          if [ -f "$STATE_FILE" ]; then
            log "External STANDBY seen while Framework PC is active source - reasserting: $line"
            cec-ctl -d "$DEV" --to 0 --image-view-on --no-reply >/dev/null 2>&1
            cec-ctl -d "$DEV" --active-source "phys-addr=$MY_PHYS" --no-reply >/dev/null 2>&1
          else
            log "External STANDBY seen while Framework PC was not active source - suspending to match: $line"
            systemctl suspend
          fi
          ;;
      esac
    done
  }
  log "CEC monitor pipe closed (device bounce?) - reacquiring $DEV"
done
