# Fresh-machine smoke test

Installs the module on an empty Windows and runs it **without administrator
rights**, in a throwaway Windows Sandbox.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\FreshMachine\Invoke-FreshMachineTest.ps1
```

It is not part of `test.ps1`. Pester discovers `*.Tests.ps1` only, so nothing
here runs with the suite; it needs a hypervisor and several minutes, and it
belongs before a release rather than before a commit.

## Why it exists

Three defects shipped in one day that nothing else could have caught, because
each is invisible on a machine where the module already works.

| Defect | Why the suite missed it |
|---|---|
| The elevated relaunch command did not parse, so the child exited 1 before running a line | Self-elevation only happens when the session is **not** already an administrator, and development sessions were |
| The documented install required `pwsh` | Which does not exist until this module installs it |
| The documented install worked exactly once | The second run found the version folder already there |

Each was found by a person on a new laptop, twice within twenty seconds.

## Why not CI

The obvious answer does not work. The `windows-latest` runner executes as an
administrator, so `Test-IsAdministrator` returns true and the self-elevation
path is never reached — the exact code that broke stays untested. It also ships
PowerShell 7, so the missing-`pwsh` case cannot arise. Both of the bugs this is
for are unreachable on a hosted runner.

Windows Sandbox is the right shape instead: genuinely empty, Windows PowerShell
only, discarded afterwards.

## What it checks

- The machine really is fresh — `pwsh` is absent before anything runs
- The install command **from README.md**, run twice. The second run is what
  `-Force` exists for
- The module imported and the run reached its summary, with `FailedCount` a
  number
- The payload ran with no administrator rights, so self-elevation was exercised
- **Two** transcripts appeared: the parent's, recording the handoff, and the
  elevated child's own. One means the child died before it could log, which is
  precisely how the relaunch parse error presented

The install command is read out of `README.md` rather than copied here. A smoke
test carrying its own copy tests the copy, and two of the three defects above
were *in* the documented command.

## What it does not check, in Windows Sandbox

**The last two are reported `N/A` here, and the elevation path is not covered.**

Windows Sandbox ships with UAC off, and turning it back on needs a restart a
disposable machine cannot perform. With `EnableLUA=0` there is no split token:
everything runs elevated, `RunLevel Limited` cannot produce an unelevated child,
and `Update-Everything` never reaches self-elevation at all.

So of the three defects that motivated this, Sandbox covers two — the missing
`pwsh` and the `-Force` reinstall — and **not** the relaunch parse error, which
was the worst of them.

The first version of this harness reported those checks as failures. That was
wrong in a way worth naming: it showed red for something the module did not do,
and a suite that cries wolf is one people stop reading. They now report `N/A`
with the reason, the run still passes, and the summary says how many checks it
could not make.

Real elevation coverage needs a VM that can boot with UAC on — a Hyper-V
checkpoint restored between runs. That is a heavier harness than this one and
has not been built.

## The UAC part

Self-elevation raises a prompt, and an unattended test cannot click it. Turning
UAC off is not the workaround: `Test-ElevationCapability` reads `EnableLUA` and
refuses the run outright when it is `0`, so the harness would measure the
refusal rather than the handoff.

The harness leaves `EnableLUA` at `1` and sets `ConsentPromptBehaviorAdmin` to
`0` — elevate without prompting. UAC stays enabled, the capability check still
passes, and the child starts with nobody at the keyboard. This happens inside
the sandbox and is discarded with it; the host is untouched.

## One at a time, with a gap

Windows runs one sandbox at a time, and starting a second does nothing at all —
no window, no error, no clue. The launcher refuses to start when one is already
open, and `-CloseExistingSandbox` closes it first.

Closing is not the end of it. `vmmemWindowsSandbox` holds the virtual machine's
memory and the hypervisor reclaims it on its own schedule, over a minute or more
after the session processes are gone. **A sandbox started during that window
starts and then never runs its logon command** — processes appear, nothing is
written to the mapped folder, and the run waits out its whole timeout reporting a
failure that belongs to the timing.

Measured here: two runs 2m31s apart. The first passed. The second left
`WindowsSandboxServer` and `WindowsSandboxRemoteSession` alive for twenty-five
minutes without writing `logon.txt`.

So the launcher waits for `vmmemWindowsSandbox` to go before it starts, up to
three minutes, and says why if it does not. It waits on that name and never on a
bare `vmmem`, which belongs to WSL on any machine that has it and would never
clear.

## Prerequisites

Checked before anything is created, each with what to do about it:

- Windows Pro, Enterprise or Education
- Virtualization enabled in firmware
- Windows Sandbox turned on:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All
```

The sandbox needs a network, because the install command fetches the module from
GitHub — so it tests `main`, not the working copy. That is deliberate: it is the
path a new user takes.

## Files

| File | Runs |
|---|---|
| `Invoke-FreshMachineTest.ps1` | On the host. Checks prerequisites, writes the `.wsb`, starts the sandbox, waits, reports |
| `Sandbox\Start-Harness.ps1` | Inside, elevated, from the logon command |
| `Sandbox\Invoke-UnelevatedRun.ps1` | Inside, **unelevated**, via a scheduled task at `RunLevel Limited` |

That last hop is the one that matters. A scheduled task at `RunLevel Limited` is
how an elevated session starts a genuinely unelevated child of the same user;
without it the harness would run as an administrator and test nothing.
