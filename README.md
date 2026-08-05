# framework-cec-daemon

A single systemd daemon that makes a Linux HTPC (built and tested on a
[Framework Desktop](https://frame.work/desktop) with its HDMI Expansion
Card) behave properly on an HDMI-CEC bus shared with a TV, AVR, and other
CEC devices (e.g. an Apple TV) — without getting knocked off active source
by another device's bad CEC behavior, and without losing track of its own
state across the inevitable USB hiccups some CEC adapters cause.

## What it actually does

- **Claims a CEC identity** (`playback`) and holds it open for as long as
  the daemon runs.
- **One Touch Play on wake/boot**: sends `<Image View On>` then
  `<Active Source>`, retrying through a cold-wake window and then
  re-asserting through a "settle window" — because some devices (looking at
  you, Apple TV) reflexively re-claim active source as part of their own
  wake sequence regardless of who actually triggered the wake.
- **Defends against a real bug**: some CEC devices broadcast `<Standby>`
  even when they have no business ending someone else's active session.
  This daemon overrides that broadcast (re-asserts itself) when it's
  currently active source, instead of obeying it — while still correctly
  obeying an authoritative `<Standby>` from the TV or AVR itself.
- **Tracks routing changes via `<Routing Change>`**, not just
  `<Active Source>` — so a manual remote button press on the AVR (which
  doesn't touch CEC otherwise on some receivers) still keeps the daemon's
  state in sync.
- **Suspend/resume and shutdown cleanup** via a `systemd-logind` sleep
  inhibitor + the `PrepareForSleep` DBus signal, and a `SIGTERM` trap —
  broadcasts `<Standby>` to the rest of the system if (and only if) it was
  the active source, so downstream gear doesn't stay powered on to a dead
  input.
- **Survives the adapter bouncing.** Some USB HDMI-CEC adapters fully
  disconnect and re-enumerate at the USB level every time HDMI hotplug
  drops — this happens on essentially every TV/AVR power-cycle. The daemon
  recovers internally (a `while true` reacquire loop) instead of relying on
  `systemd`'s restart delay, and — critically — never wipes its own
  "am I active" state just because it had to restart.

## Requirements

- A CEC-capable adapter exposing a `/dev/cecN` character device
  (`v4l-utils`' `cec-ctl` is used throughout).
- `systemd` (for the inhibitor/`PrepareForSleep` mechanism and the trap-based
  shutdown hook).
- `busctl` (ships with `systemd`).
- Root, or a systemd service running as root — claiming a CEC logical
  address and holding a sleep inhibitor both need it.

## Installation

```bash
sudo ./install.sh
```

This installs `cec-daemon.sh` to `/usr/local/bin/`, the unit file to
`/etc/systemd/system/`, and enables + starts it immediately.

## Before you install: things you'll need to customize

This was built for one specific setup and has a few hardcoded values you
should change for your own hardware in `cec-daemon.sh`:

- `DEV=/dev/cec0` — your adapter's device node.
- `--osd-name "Framework PC"` — the name your device announces on the bus.
- `CONTROLLER_MAC` — a Bluetooth game controller's MAC address that gets
  disconnected before every suspend/shutdown, because it kept reconnecting
  and immediately waking the PC back up. Delete this call entirely if it
  doesn't apply to you.

## Design notes (why it's shaped this way)

This started as four separate units — a bus-watching daemon, a boot-time
wake script, a shutdown hook, and a suspend/resume hook — each independently
reading and writing the same "am I active source" state at different
trigger points. Every real bug found while building this traced back to
that shape: state getting clobbered by the daemon's own restart, a write
silently going unrecognized because of a hardcoded CEC logical-address name
(these are assigned dynamically depending on what else is claimed on the
bus — don't hardcode "Playback Device 3", match "Playback Device" generically
instead), and an ad-hoc reassert accidentally running unrelated
shutdown-only side effects because two different units happened to share
one systemd `restart` command.

Consolidating into one process fixed all of that — but it introduces its
own sharp edge worth knowing about: **a routine `systemctl restart` sends
the exact same `SIGTERM` a real system shutdown does.** Nothing at the
signal level distinguishes "I'm deploying a fix" from "the system is
powering off." This daemon checks `systemctl is-system-running` inside its
`SIGTERM` trap — it reports `"stopping"` specifically during an actual
system-wide shutdown/sleep transition, and something else otherwise — so a
plain restart doesn't broadcast a disruptive `<Standby>` to your whole
home theater.

Another one: `hold_inhibitor`/`release_inhibitor` get called both from the
top level of the script and from inside the `busctl monitor | { ... }`
pipeline, which runs in its own subshell (piped commands always do).
Subshells don't share variable mutations with their parent — a plain shell
variable for the held inhibitor PID will silently desync and leak an
orphaned process on the first suspend/resume cycle. It's tracked via a file
instead, for the same reason `STATE_FILE` is.

## License

MIT — see [LICENSE](LICENSE).
