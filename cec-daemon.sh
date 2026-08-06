#!/bin/bash
# Explicit state-machine CEC daemon for the Framework HDMI Expansion Card.
#
# Replaces the earlier design where a backgrounded wake-sequence job raced
# the main claim-holding loop (root cause of a real bug 2026-08-05: the
# wake commands could fire before the CEC identity claim had actually
# completed, silently no-op, while a stale <Routing Change> left over from
# before a reboot made the daemon believe it had succeeded anyway - nothing
# was ever sent to the TV/AVR). More generally, EVERY bug found while
# building this daemon (state wiped on restart, a write silently
# unrecognized due to a hardcoded LA name, an inhibitor-PID leaked across a
# subshell boundary, a routine restart broadcasting a real shutdown
# command) traced back to the same root shape: multiple concurrent code
# paths mutating shared state independently, with no single sequential
# flow of control.
#
# This version has exactly one state variable, mutated from exactly one
# place: a single event loop that reads every event - CEC bus lines AND
# systemd-logind's PrepareForSleep DBus signal - through one shared FIFO,
# in arrival order. Retries are driven by read timeouts inside that same
# loop, not by a second thread of control.
#
# States:
#   CLAIMING  - device/identity not yet confirmed usable.
#   WAKING    - sent an initial claim attempt, retrying on a timer,
#               bounded by WAKE_MAX_ATTEMPTS.
#   SETTLING  - claim confirmed once, but still within the settle window -
#               keep re-asserting if lost, to outlast a device (e.g. the
#               Apple TV) that reflexively re-claims active source as part
#               of its own power-on sequence, confirmed independent of who
#               triggered the wake. Bounded by SETTLE_WINDOW_ROUNDS.
#   ACTIVE    - settled. Defends against a disruptive external <Standby>
#               broadcast INDEFINITELY (not time-boxed to the settle
#               window) - this is the actual original bug this daemon
#               exists to fix, and it happens during genuine ongoing use,
#               well after any boot/wake window. Still yields immediately,
#               unconditionally, to a real <Active Source> claim or
#               <Routing Change> away from us - that's a legitimate
#               source switch, not a takeover attempt, and always allowed
#               regardless of how long we've been active.
#   INACTIVE  - not the active source. No defense - follows any <Standby>.
set -uo pipefail

# --- Tunables (named, not inlined, so the retry/timing shape is legible
# and adjustable in one place) ---
DEV=/dev/cec0
OSD_NAME="Framework PC"
CONTROLLER_MAC=C8:3F:26:91:BF:58
WAKE_MAX_ATTEMPTS=15            # bounded discovery retries from cold/deep-off
WAKE_RETRY_INTERVAL_SEC=2
SETTLE_WINDOW_ROUNDS=6           # rounds spent outlasting a reflexive re-claim
SETTLE_ROUND_INTERVAL_SEC=3
DEVICE_POLL_INTERVAL_SEC=0.2     # how often to check for the adapter's return after a bounce

STATE_DIR=/run/cec-guard
EVENT_FIFO="$STATE_DIR/events"
INHIBIT_PID_FILE="$STATE_DIR/inhibit-pid"
mkdir -p "$STATE_DIR"
[ -p "$EVENT_FIFO" ] || mkfifo "$EVENT_FIFO"

log() { logger -t cec-daemon "$1"; }

# Run a command, capturing its output instead of discarding it. Blanket
# `>/dev/null 2>&1` on action commands was the standing pattern here until
# it got called out as a bad default: it's the same "assume success, don't
# check" shape that let the 2026-08-05 wake-sequence race hide (failed
# cec-ctl calls left zero trace of *why*, only inferrable after the fact
# from what was missing on the bus) and later blocked diagnosing whether
# `bluetoothctl disconnect` was even running during a real suspend. Always
# log on failure; log on success too only if the command actually said
# something, so the routine WAKING retry loop doesn't spam the journal.
run() {
  local output status
  output=$("$@" 2>&1)
  status=$?
  if [ "$status" -ne 0 ]; then
    log "FAILED (exit $status): $* -- ${output:-<no output>}"
  elif [ -n "$output" ]; then
    log "$*: $output"
  fi
}

# --- Sleep inhibitor (unchanged mechanism from the previous version -
# still file-based since it's set from the main loop and released from
# event handling, both within this same process but worth keeping
# explicit rather than assuming a bare variable is safe here too) ---
hold_inhibitor() {
  systemd-inhibit --what=sleep --mode=delay --who="cec-daemon" \
    --why="CEC standby broadcast + controller disconnect before suspend" \
    sleep infinity &
  echo "$!" > "$INHIBIT_PID_FILE"
}

release_inhibitor() {
  if [ -f "$INHIBIT_PID_FILE" ]; then
    # Deliberate, narrow suppression, not the old blanket default: the
    # only realistic failure here is ESRCH because the inhibitor job
    # already exited on its own - an expected, harmless race, not
    # something worth a log line every time it happens.
    kill "$(cat "$INHIBIT_PID_FILE")" 2>/dev/null
    rm -f "$INHIBIT_PID_FILE"
  fi
}

# --- CEC actions ---
MY_PHYS=""

send_wake() {
  run cec-ctl -d "$DEV" --to 0 --image-view-on --no-reply
  run cec-ctl -d "$DEV" --active-source "phys-addr=$MY_PHYS" --no-reply
  # Image View On + Active Source only reliably wakes the TV - some AVRs
  # don't auto-follow the TV's power state (confirmed 2026-08-05: the
  # Marantz stayed in standby while the TV/projector woke fine). This is
  # the standard CEC message for "please power on and route audio for
  # me", sent directly to the Audio System rather than relying on a
  # cascade that isn't guaranteed to happen.
  run cec-ctl -d "$DEV" --to 5 --system-audio-mode-request "phys-addr=$MY_PHYS" --no-reply
}

send_standby_broadcast() {
  # --to 15 (broadcast) is required: cec-ctl refuses to send --standby at
  # all without an explicit destination.
  run cec-ctl -d "$DEV" --to 15 --standby --no-reply
}

do_suspend() {
  systemctl suspend
}

pre_sleep_cleanup() {
  # Shared by real suspend (PrepareForSleep) and shutdown (SIGTERM) - "we
  # are about to leave the bus" either way.
  run bluetoothctl disconnect "$CONTROLLER_MAC"
  if [ "$STATE" = "ACTIVE" ] || [ "$STATE" = "SETTLING" ]; then
    log "we were active source - broadcasting standby"
    send_standby_broadcast
  else
    log "we were NOT recognized as active source - skipping standby broadcast"
  fi
}

on_term() {
  # A plain "systemctl restart" sends the same SIGTERM a real shutdown
  # does - is-system-running distinguishes an actual system-wide
  # shutdown/sleep transition ("stopping") from a routine unit restart.
  if [ "$(systemctl is-system-running 2>/dev/null)" = "stopping" ]; then
    # "stopping" alone doesn't distinguish a reboot from a real
    # poweroff/halt - both activate a system-wide shutdown-like
    # transition. A reboot means Framework is coming right back; the
    # rest of the home theater shouldn't be told to stand down just
    # because Framework itself needs to restart. Only a genuine
    # poweroff/halt means the session is actually ending.
    # `systemctl is-active reboot.target` is NOT reliable here - it only
    # reports success for the literal "active" state, but reboot.target
    # is still "activating" (not yet "active") at the exact moment this
    # daemon gets stopped, since stopping it is itself part of the
    # process of reaching that target. Confirmed live 2026-08-05: this
    # exact check silently failed and fell through to the full cleanup
    # path during a real reboot test. Checking the job queue instead -
    # the reboot job is present there for the whole shutdown transaction,
    # not just once the target is fully settled.
    if systemctl list-jobs --no-legend 2>/dev/null | grep -q 'reboot\.target'; then
      log "System is rebooting, not powering off - leaving the rest of the home theater alone, Framework will reclaim active source on the next boot"
    else
      pre_sleep_cleanup
    fi
  else
    log "SIGTERM received but system is not shutting down (routine restart) - skipping standby broadcast"
  fi
  release_inhibitor
  exit 0
}
trap on_term TERM

# --- Event sources: both write into the same FIFO, prefixed by origin,
# so the state machine below is the only consumer and only mutator of
# state regardless of which source an event came from. ---

# CEC bus reader: owns reacquiring the device after a bounce (the
# Expansion Card fully disconnects/re-enumerates at the USB level on
# every HDMI HPD drop - confirmed via kernel logs, not just a CEC-level
# state change - so this is the normal case, not an edge case).
(
  while true; do
    if [ ! -e "$DEV" ]; then
      sleep "$DEVICE_POLL_INTERVAL_SEC"
      continue
    fi
    cec-ctl -d "$DEV" --playback --osd-name "$OSD_NAME" --monitor -s 2>&1 |
      while IFS= read -r line; do
        printf 'CEC:%s\n' "$line" > "$EVENT_FIFO"
      done
    printf 'CEC_BOUNCE:\n' > "$EVENT_FIFO"
  done
) &

# DBus sleep/resume signal reader. stderr is routed through log(), not
# discarded - a silent connection failure here would mean the daemon just
# never sees another sleep/resume event again, with no trail explaining
# why.
(
  busctl monitor --match="type='signal',interface='org.freedesktop.login1.Manager',member='PrepareForSleep'" \
    2> >(while IFS= read -r errline; do log "busctl monitor: $errline"; done) |
    while IFS= read -r line; do
      printf 'DBUS:%s\n' "$line" > "$EVENT_FIFO"
    done
) &

# Keep a read+write fd open on the FIFO ourselves so `read` never sees
# EOF just because a writer momentarily isn't connected.
exec 3<>"$EVENT_FIFO"

# --- State machine ---
STATE="CLAIMING"
wake_attempts=0
settle_round=0
reclaim_after_bounce=0   # set when a bounce interrupts ACTIVE/SETTLING, so
                         # we skip straight back to defending once reclaimed
                         # instead of running the full cold-start discovery.
awaiting_new_addr=0

transition() {
  local new_state="$1"
  [ "$new_state" = "$STATE" ] || log "state: $STATE -> $new_state"
  STATE="$new_state"
  # Diagnostic only - nothing reads this back for logic, it's just so
  # `cat /run/cec-guard/state` can answer "what does the daemon currently
  # think is going on" without grepping the journal.
  echo "$STATE" > "$STATE_DIR/state"
}

while true; do
  case "$STATE" in
    WAKING|SETTLING)
      if [ "$STATE" = "WAKING" ]; then
        interval="$WAKE_RETRY_INTERVAL_SEC"
      else
        interval="$SETTLE_ROUND_INTERVAL_SEC"
      fi
      if IFS= read -t "$interval" -r -u 3 event; then
        got_event=1
      else
        got_event=0
      fi
      ;;
    *)
      IFS= read -r -u 3 event
      got_event=1
      ;;
  esac

  if [ "$got_event" -eq 0 ]; then
    # Timed out waiting for confirmation - act on the retry/settle clock.
    case "$STATE" in
      WAKING)
        wake_attempts=$((wake_attempts + 1))
        if [ "$wake_attempts" -ge "$WAKE_MAX_ATTEMPTS" ]; then
          log "gave up after $WAKE_MAX_ATTEMPTS attempts - active-source claim never confirmed"
          transition INACTIVE
        else
          send_wake
        fi
        ;;
      SETTLING)
        settle_round=$((settle_round + 1))
        if [ "$settle_round" -ge "$SETTLE_WINDOW_ROUNDS" ]; then
          log "active-source claim held through settle window"
          transition ACTIVE
        fi
        # Re-assertion on a lost claim happens reactively (see the
        # "someone else claimed/routed away" handling below), not here -
        # if we're still in SETTLING with no contrary event, we're still
        # holding it.
        ;;
    esac
    continue
  fi

  origin="${event%%:*}"
  line="${event#*:}"

  case "$origin" in
    CEC_BOUNCE)
      log "CEC monitor pipe closed (device bounce) - reacquiring $DEV"
      if [ "$STATE" = "ACTIVE" ] || [ "$STATE" = "SETTLING" ]; then
        reclaim_after_bounce=1
      fi
      transition CLAIMING
      ;;

    DBUS)
      case "$line" in
        *"BOOLEAN true"*)
          log "PrepareForSleep(true) - about to suspend"
          pre_sleep_cleanup
          release_inhibitor
          ;;
        *"BOOLEAN false"*)
          log "PrepareForSleep(false) - resumed"
          hold_inhibitor
          wake_attempts=0
          settle_round=0
          transition WAKING
          send_wake
          ;;
      esac
      ;;

    CEC)
      case "$line" in
        *"Event: State Change: PA:"*)
          # e.g. "Initial Event: State Change: PA: 1.1.0.0, LA mask: 0x0000"
          # or "8.14: Event: State Change: PA: 1.1.0.0, LA mask: 0x0100" -
          # a nonzero LA mask is the adapter's own confirmation that the
          # identity claim actually completed. Only start sending once
          # we've seen this - this is the actual fix for the 2026-08-05
          # race (the old design assumed the claim was ready instead of
          # waiting for evidence of it).
          MY_PHYS=$(echo "$line" | sed -n 's/.*PA: \([0-9a-fA-F.]*\),.*/\1/p')
          la_mask=$(echo "$line" | sed -n 's/.*LA mask: \(0x[0-9a-fA-F]*\).*/\1/p')
          if [ "$STATE" = "CLAIMING" ] && [ -n "$la_mask" ] && [ "$la_mask" != "0x0000" ]; then
            wake_attempts=0
            if [ "$reclaim_after_bounce" -eq 1 ]; then
              reclaim_after_bounce=0
              settle_round=0
              transition SETTLING
              send_wake
            else
              transition WAKING
              send_wake
            fi
          fi
          ;;

        "Transmitted by Playback Device"*"ACTIVE_SOURCE (0x82)"*)
          # Our own claim, recognized regardless of which LA slot we
          # landed on this session (these are assigned dynamically - never
          # match a specific "Playback Device N").
          case "$STATE" in
            WAKING) transition SETTLING ;;
            CLAIMING|INACTIVE) settle_round=0; transition SETTLING ;;
          esac
          ;;

        "Received from"*"ACTIVE_SOURCE (0x82)"*)
          # Precise opcode match, not just a substring - REQUEST_ACTIVE_SOURCE
          # (0x85) contains "ACTIVE_SOURCE" too and is a completely different
          # message (a question, not a claim) - confirmed live 2026-08-05
          # this was being misread as a contest. Someone else's real claim.
          # What this means depends on WHEN it
          # arrives - CEC carries no "why" information, so intent has to
          # be inferred from timing, not the message itself:
          #   - During WAKING/SETTLING: this is exactly the contest the
          #     settle window exists to fight through (the Apple TV's
          #     reflexive boot-time re-claim looks identical on the wire
          #     to a genuine switch-away - fight back immediately rather
          #     than surrendering on the first contest, bounded by the
          #     existing settle-round budget either way).
          #   - Once settled into ACTIVE: always yield immediately - a
          #     source switch at that point is a deliberate user action,
          #     not a boot-time race, and is always allowed.
          case "$STATE" in
            WAKING|SETTLING)
              log "contested during settle window - reasserting: $line"
              send_wake
              transition SETTLING
              ;;
            ACTIVE)
              transition INACTIVE
              ;;
          esac
          ;;

        "Received from"*"ROUTING_CHANGE"*)
          awaiting_new_addr=1
          ;;
        *"new-phys-addr:"*)
          if [ "$awaiting_new_addr" = "1" ]; then
            awaiting_new_addr=0
            new_addr=$(echo "$line" | awk '{print $2}')
            if [ "$new_addr" = "$MY_PHYS" ]; then
              log "Routing changed to us ($MY_PHYS)"
              transition ACTIVE
            else
              case "$STATE" in
                WAKING|SETTLING|ACTIVE)
                  # Unlike a device's own reflexive ACTIVE_SOURCE
                  # announcement, a routing change is the AVR/TV - the
                  # actual routing hub - explicitly repointing itself.
                  # Treated as authoritative even during the settle
                  # window, not fought.
                  log "Routing changed away from us (to $new_addr)"
                  transition INACTIVE
                  ;;
              esac
            fi
          fi
          ;;

        "Received from TV"*"STANDBY (0x36)"*|"Received from Audio System"*"STANDBY (0x36)"*)
          # Authoritative - the display or the AVR itself is ending the
          # session. Always follow, regardless of state.
          log "TV/AVR went to standby - suspending to match: $line"
          transition INACTIVE
          do_suspend
          ;;

        "Received from"*"STANDBY (0x36)"*)
          if [ "$STATE" = "ACTIVE" ]; then
            # The one indefinite defense in this daemon - see the header
            # comment on why this must NOT be time-boxed to the settle
            # window.
            log "External STANDBY seen while active source - reasserting: $line"
            send_wake
          else
            log "External STANDBY seen while not active source - suspending to match: $line"
            do_suspend
          fi
          ;;

        *)
          # Every opcode not specifically acted on above still gets
          # logged, by name, so cec-daemon's own journal is a complete
          # record of bus activity - not just the opcodes we chose to
          # react to. This is what should have made the 2026-08-05
          # "how did the AVR switch inputs" investigation a one-command
          # answer instead of a manual cross-reference against the
          # separate raw-monitor service's log.
          #
          # Opcode name is extracted from the line itself rather than
          # matched against a hand-maintained list, so this stays
          # complete even for opcodes not otherwise anticipated. Only
          # real opcode header lines ("Transmitted by ..."/"Received
          # from ..." followed by "OPCODE_NAME (0xNN)") match the "): "
          # shape below - parameter/continuation lines (e.g.
          # "        phys-addr: ...") don't, and are silently skipped;
          # they belong to whichever header line was already logged.
          opcode=$(echo "$line" | sed -n 's/.*): \([A-Za-z0-9_]*\) (0x[0-9a-fA-F]*).*/\1/p')
          if [ -n "$opcode" ]; then
            log "unhandled opcode $opcode: $line"
          fi
          ;;
      esac
      ;;
  esac
done
