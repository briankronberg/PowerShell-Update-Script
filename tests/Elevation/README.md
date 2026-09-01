# Self-elevation test

Runs `Update-Everything` **without administrator rights** on this machine, and
checks that the elevated child starts, runs, and leaves its own transcript.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Elevation\Invoke-ElevationTest.ps1
```

A UAC prompt appears and you answer it. That click is why this is not part of
`test.ps1`.

## Why it exists

The one thing nothing else covers.

| Where | Why the handoff is never reached |
|---|---|
| Development machines | already an administrator, so `Test-IsAdministrator` returns true |
| `windows-latest` CI | same |
| Windows Sandbox | ships with `EnableLUA=0`; no split token, so `RunLevel Limited` cannot make an unelevated child |

The relaunch command shipped unable to parse, and every non-elevated run hit it —
which is to say every ordinary first run. It reached a laptop because no test
could reach the code.

## What it checks

- UAC is on, so elevation means something
- The run really started **without** administrator rights
- It elevated rather than carrying on unelevated
- The parent reported the child's exit code
- `FailedCount` came back as a number
- **Two transcripts.** The parent's, recording the handoff, and the elevated
  child's own. One means the child died before it could log, which is precisely
  how the relaunch parse error presented
- The elevated run reached its summary, so it ran rather than merely started

## What it changes

Nothing. No registry values, no installs, and the scheduled task used to drop
privileges is removed whether the run succeeds or fails.

Notably it does **not** set `ConsentPromptBehaviorAdmin` to 0. The Sandbox
harness does that inside a disposable machine; doing it to a real one to save a
click would be trading a person's security settings for convenience.

## Running it from an elevated session

It handles that. A scheduled task at `RunLevel Limited` is how an elevated
session starts a genuinely unelevated child of the same user — without it the
test would run as an administrator and measure nothing, which is exactly how the
relaunch shipped broken.

## When the module declines to elevate

Reported as `N/A` with the module's own reason, not as a failure, because whether
a refusal is correct depends on the account and this harness cannot settle it:

- A genuine standard user **should** be refused
- An account elevated through a **privilege-management broker** — BeyondTrust,
  CyberArk EPM, Admin By Request and others — is *not* in the local
  Administrators group and can still elevate

Both look identical from here. The first run of this test hit the second case on
a corporate laptop: not a member of the group, `Avecto Defendpoint Service`
running, and elevated sessions working all day. See the issue linked from the
run's note.

## Coverage, honestly

Together with `tests/FreshMachine`, the three defects that motivated a harness at
all are covered:

| Defect | Covered by |
|---|---|
| The elevated relaunch did not parse | **this test** |
| The documented install required `pwsh` | fresh-machine |
| The documented install worked exactly once | fresh-machine |

An unattended version needs a VM that boots with UAC on and a checkpoint restored
between runs — Hyper-V, a Windows image, and a machine willing to host it. This
one needs a click, and gets the same answer today.
