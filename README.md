# framework-cec-daemon

A single systemd daemon that makes a Linux HTPC (built and tested on a
[Framework Desktop](https://frame.work/desktop) with its HDMI Expansion
Card) behave properly on an HDMI-CEC bus shared with a TV, AVR, and other
CEC devices (e.g. an Apple TV) — without getting knocked off active source
by another device's bad CEC behavior, and without losing track of its own
state across the inevitable USB hiccups some CEC adapters cause.

## What it actually does

The daemon is an explicit state machine — `CLAIMING` → `WAKING` →
`SETTLING` → `ACTIVE`/`INACTIVE` — driven by a single sequential event
loop. Every event, whether from the CEC bus or from `systemd-logind`'s
sleep/resume signal, funnels through one shared FIFO and is handled one at
a time by the one piece of code that owns state. See "Design notes" below
for why that matters.

- **Claims a CEC identity** (`playback`) and holds it open for as long as
  the daemon runs.
- **One Touch Play on wake/boot**: sends `<Image View On>` + `<Active
  Source>` to the TV, and `<System Audio Mode Request>` directly to the
  Audio System — some AVRs don't reliably auto-follow the TV's power-on
  cascade, so this asks it directly instead of assuming it will follow
  along. Retries through a cold-wake window (`WAKING`), then keeps
  re-asserting through a bounded "settle window" (`SETTLING`) — because
  some devices (looking at you, Apple TV) reflexively re-claim active
  source as part of their own wake sequence, regardless of who actually
  triggered the wake.
- **Two different rules for two different kinds of contest, on purpose:**
  an `<Active Source>` claim from another device is only fought during
  `WAKING`/`SETTLING` (outlasting that reflexive boot-time re-claim) — once
  settled into `ACTIVE`, any real claim or `<Routing Change>` away is
  yielded to immediately, no fight. But a disruptive `<Standby>` broadcast
  from a device with no business ending your session is defended
  **indefinitely** while `ACTIVE`, not just during the settle window —
  that's the actual bug this project exists to fix, and it happens during
  genuine ongoing use, not at boot. Time-boxing that one would silently
  reintroduce the bug.
- **Tracks routing changes via `<Routing Change>`**, not just
  `<Active Source>` — so a manual remote button press on the AVR (which
  doesn't touch CEC otherwise on some receivers) still keeps the daemon's
  state in sync.
- **Suspend/resume and shutdown cleanup** via a `systemd-logind` sleep
  inhibitor + the `PrepareForSleep` DBus signal, and a `SIGTERM` trap —
  broadcasts `<Standby>` to the rest of the system if (and only if) it was
  the active source, so downstream gear doesn't stay powered on to a dead
  input. The trap distinguishes a real shutdown from a routine
  `systemctl restart` (see "Design notes") so deploying an update doesn't
  itself broadcast a disruptive standby.
- **Survives the adapter bouncing — fast.** Some USB HDMI-CEC adapters
  fully disconnect and re-enumerate at the USB level every time HDMI
  hotplug drops — this happens on essentially every TV/AVR power-cycle.
  A bounce while `ACTIVE`/`SETTLING` skips straight back into defending
  once the adapter returns, instead of re-running the full cold-wake
  discovery loop.
- **Logs every CEC opcode it sees**, not just the ones it acts on — the
  opcode name is parsed straight from the bus line rather than matched
  against a fixed list, so the daemon's own log is a complete record of
  bus activity even for opcodes nobody anticipated. Useful for exactly the
  kind of "wait, what actually happened" investigation this project has
  needed more than once.

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

This went through two earlier shapes before landing here, and both left
real lessons worth knowing if you're modifying this.

**Shape 1** was four separate systemd units — a bus-watching daemon, a
boot-time wake script, a shutdown hook, a suspend/resume hook — each
independently reading and writing the same "am I active source" state at
different trigger points. Every bug traced back to that: state getting
clobbered by the daemon's own restart, a write silently going unrecognized
because of a hardcoded CEC logical-address name (these are assigned
dynamically depending on what else is claimed on the bus — never hardcode
"Playback Device 3", match "Playback Device" generically instead), an
ad-hoc reassert accidentally running unrelated shutdown-only side effects
because two units happened to share one `systemctl restart`.

**Shape 2** consolidated to one process, but still had a background wake
sequence and a backgrounded DBus listener each independently touching
shared state — which fixed most of shape 1's bugs but not the underlying
pattern, and produced a new one: the backgrounded wake sequence could race
the main loop's own CEC identity claim and fire before it was ready,
silently sending nothing at all while the daemon still believed it had
succeeded (a stale `<Routing Change>` left over from before a reboot was
enough to satisfy the "did it work" check with zero real command sent to
the TV).

**Current shape**: exactly one sequential event loop, one state variable,
mutated from exactly one place. CEC bus lines and the DBus
`PrepareForSleep` signal both get written into a single shared FIFO
(prefixed `CEC:`/`DBUS:`), and the state machine is the only thing that
ever reads from it. Retries are driven by `read -t` timeouts inside that
same loop rather than a second thread of control. This closes the whole
*class* of bug rather than patching each instance — there is no longer a
"which other piece of code might be touching this state right now"
question to get wrong, because nothing else does.

Two sharp edges worth knowing about regardless of shape:

- **A routine `systemctl restart` sends the exact same `SIGTERM` a real
  system shutdown does.** Nothing at the signal level distinguishes
  "deploying a fix" from "the system is powering off." The `SIGTERM` trap
  checks `systemctl is-system-running` — it reports `"stopping"`
  specifically during an actual system-wide shutdown/sleep transition, and
  something else otherwise — so a plain restart doesn't broadcast a
  disruptive `<Standby>` to your whole home theater.
- **CEC opcode names collide as substrings.** `REQUEST_ACTIVE_SOURCE`
  contains `ACTIVE_SOURCE`; a naive `case` pattern matching on the
  substring will misread a question ("who's active?") as an actual claim.
  Always match the opcode's hex number too (`"ACTIVE_SOURCE (0x82)"`), not
  just the name.

## License

MIT — see [LICENSE](LICENSE).
