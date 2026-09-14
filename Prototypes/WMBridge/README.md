# WMBridge Desktop creation experiment

ATE-40 is an isolated feasibility experiment. Read [the original findings](FINDINGS.md)
and the [latest end-to-end evidence](Evidence/2026-09-14-ready-flow.md) before
running it. On this macOS 26.5.2 session, WMBridge creation plus a short-lived
virtual display refresh produces a Desktop that native adjacent switching can
enter. This remains prototype research; production creation is unchanged.

For a manual trial, quit Atelier and run this from the `ate-40` workspace in
your disposable GUI session with one display:

```sh
mise run desktop:create -- --enter
```

The command detects the display, requests creation once, places the new Desktop
immediately after the current one, and briefly creates/releases a private virtual
display to make Dock reconcile its Desktop list. It verifies the original display
configuration and Dock's count. Capability checking and creation share one native
invocation; the probe is retained in `creation/intent.json`. Once display callbacks
settle and Dock agrees with the fresh topology, entry can proceed while the
one-second display setup UI observation continues. The command prints its elapsed
time, including helper build/startup. See the
[latency measurements](Evidence/2026-09-14-creation-latency.md).
`--enter` uses the enabled native next-Desktop
shortcut; omit it to keep the current Desktop active. New numbered shortcut
registrations remain unavailable, so use adjacent switching or Mission Control.
`--raw` retains the original WMBridge-only creation trial. It saves private logs
under `.build/ate-40-manual/` and prints commands to inspect and clean up that
specific trial. Check whether Mission Control shows the new Desktop, whether
you can enter it with your usual controls, and whether you can type in a saved
test window. Return to an original Desktop before cleanup, and reopen Atelier
when finished. Do not repeat creation after an uncertain result; inspect the
saved trial first. `mise run desktop:create -- --help` describes the interface;
`mise run desktop:create -- --check` only runs the read-only probe.

If the returned ID exists but Mission Control omits it, run `mise run
desktop:diagnose -- /absolute/trial-directory`. This saves per-Space values,
a trace of the answering read delegates, and the saved Desktop configuration
alongside the original trial. Preferences can lag live state; the comparison
does not replace a manual visibility check. See the
[registration diagnosis](Evidence/2026-09-14-registration-diagnosis.md).

The [activation and Dock follow-up](Evidence/2026-09-14-activation-and-dock-refresh.md)
demonstrates direct activation, a visible fixture, and saved keyboard input on
the omitted Space before Mission Control could show it. The subsequent
[real display-change trial](Evidence/2026-09-14-display-refresh-confirmed.md)
made it visible and verified native thumbnail/adjacent entry with saved typing.
The [end-to-end follow-up](Evidence/2026-09-14-ready-flow.md) supplies a refresh
without changing the original resolution and confirms native adjacent entry with
saved typing. Numbered registration remains a separate limitation. Diagnosis reads
Dock's own Desktop count and CoreGraphics' physical/virtual mirror relationships;
neither requires opening Mission Control.

For bounded placement or activation comparisons, use the native `followup`
command with the original trial's `creation` subdirectory and a new private
output directory. `mise run wmbridge:run -- --help` lists modes. These diagnostic
trials explicitly open Mission Control for observation or restoration;
they do not test visual silence. Activation and reorder trials restore their
starting current ID/order, record restoration, and leave the owned Space present.
The `typing-check` command tests the saved fixture on an already active Desktop
without creating or switching a Space. Raw reports remain local to the trial.

Run from the repository root using mise and XcodeBuildMCP:

```sh
mise run wmbridge:probe
mise run wmbridge:run -- --help
mise run wmbridge:test
```

The default probe creates no windows or Desktops, changes no preferences, and
does not prompt for permissions. `trace-probe` additionally observes the actual
delegate call with temporary, forwarding method wrappers in this process only;
it restores the original implementations before returning.

For an explicit mutation trial, first quit Atelier and use a disposable GUI
session with one display. Create a private evidence parent, inspect the fresh
probe's display identifier, then use a **new** child directory for each attempt:

```sh
mkdir -m 700 /absolute/private-evidence
mise run wmbridge:run -- preflight DISPLAY-ID
mise run wmbridge:record -- /absolute/private-evidence/create.mov \
  create /absolute/private-evidence/trial DISPLAY-ID --disposable-session
mise run wmbridge:run -- reconcile /absolute/private-evidence/trial
mise run wmbridge:run -- cleanup /absolute/private-evidence/trial --disposable-session
```

`intent.json` precedes dispatch; `dispatch.json` preserves the returned ID before
confirmation; `result.json` records fresh topology and observations. The status
`managed-type0-confirmed` means exactly that. It does not establish a usable
Desktop, successful entry, typing readiness, or visual silence.

Each create directory and cleanup intent is exclusive. After interruption,
inspect the journal and reconcile instead of resubmitting. An unknown returned
ID cannot be inferred from a later addition and cannot be cleaned automatically.
Do not erase a journal to make another attempt possible. The native process
watchdog exits after ten seconds on standalone commands; server mutations have
the same deadline. The transport timeout never causes replay. Stop a server by
closing its stdin or sending SIGTERM to the PID from its `hello` reply. Never
stop a process by name. Retain evidence until all owned resources are reconciled.

Cleanup removes only the returned ID with its recorded native UUID. It refuses
an active/final Desktop, exclusive occupants (including minimized windows),
unavailable occupancy information, or an already dispatched cleanup. It
recognizes narrowly identified system background/menu surfaces. A window that
gained the new ID can retain its recorded memberships on original Desktops;
cleanup checks that it still has every such membership rather than moving it.
After an external display change, ordinary cleanup refuses. Only after reviewing
`reconcile` may an operator supply `--display CURRENT-DISPLAY-ID`; UUID ownership,
inactivity, occupancy, and fresh-topology checks still apply. Never select an ID
merely because it looks new or empty.

`serve` hosts the adapter inside the actual Atelier engine and uses its existing
JSON-lines protocol, target resolver, serialization, and numbered switching.
`serve-script` reads an explicit request file through that same protocol. Both
require a private state directory so shortcut recovery cannot use the user's
normal journal. Experiment commands are `wmbridgeProbe`, `wmbridgeCreate`,
`wmbridgeReconcile`, `wmbridgeCleanup`, and the saved `fixtureTyping` check; see
the command dispatch and [HS2 controller](controller.js). Mission Control
reorder remains excluded. Native creation/deletion are available only as explicit
diagnostic controls with `nativeControl: true`, a private `runDirectory`, and
display/current guards. Removal additionally requires the saved successful create
response, native UUID, and fresh occupancy checks; see `NativeControl.swift`.

`wmbridge:host` accepts a JSON options file for [host-test.js](host-test.js).
It copies the installed Atelier app into the private state directory, replaces
only that copy's self-test script, and launches its existing headless self-test
entry point. It loads no user configuration or defaults and refuses a running
Atelier instance. For example, use absolute paths in:

```json
{
  "disposableSession": true,
  "stateDirectory": "/absolute/private-evidence",
  "runDirectory": "/absolute/private-evidence/host-trial",
  "action": "create",
  "enter": true,
  "returnToBaseline": true,
  "output": "/absolute/private-evidence/host-result.json"
}
```

```sh
mise run wmbridge:build
mise run wmbridge:host -- /absolute/private-evidence/options.json
```

The copied app can have different Accessibility trust. Record denial rather
than changing security settings to force a pass. Restore the original Atelier
instance after the test copy and its helper exit.

Movies and raw local journals live under `.build/ate-40-evidence/` for this run.
They remain local and gitignored. [The committed evidence summary](Evidence/local-2026-09-13.json)
records movie hashes, frame counts, measurements, topology, and cleanup results.
The `review-recording` Swift executable decodes every video sample into contact
sheets with presentation timestamps; invoke it through XcodeBuildMCP's
`swift-package run` command. Sparse capture is not proof that no frame flashed
between captured samples.
