# Contributing

This is a personal maintenance tool published in case it is useful to someone
else. [Support is not promised](README.md#support). Pull requests are welcome
anyway, and this file exists so a change arrives shaped like the rest of the
code rather than being sent back.

Two things it records: the rules that came out of running this on real machines,
and the ways a test suite here has managed to stay green over broken code.

## Naming

`UpdateEverything` is the module. `Update-Everything` is the command it exports.
The hyphen belongs to the verb-noun function name, not to the module, the
repository, or the folder.

## The rules

These are not style preferences. Each is here because the alternative failed on
a real machine.

### Updating is not installing

Bringing something already present up to date needs no permission. Putting
something on a machine that never had it does. An interactive run asks per
component and defaults to No. A non-interactive run declines and reports the
step skipped, because there is nobody to ask. `-AllowInstall` approves in
advance, either `All` or by name.

A change that installs something silently will not be merged, however
convenient.

### Never drive an update mechanism you have not confirmed is there

Every step resolves its tool first and reports `Skipped` when it is absent.

Presence is not enough on its own. A self-updating tool also needs its *owner*
checked: `Get-ToolInstallSource` reads the executable's path, and a `uv`
installed by a package manager must be updated by that manager's step rather
than told to update itself. Calling the wrong updater produces a failure that
looks like the tool's fault.

### Probe for a capability; do not infer it from a version

`Test-ParameterSupport` asks whether the command that resolves *in this session*
has the parameter, because that is the only thing that matters. Comparing module
versions is the wrong test: what binds follows `PSModulePath` order, not the
highest version installed.

Windows PowerShell ships PowerShellGet 1.0.0.1, which predates `-AcceptLicense`.
Splatting it there is a terminating error, and it took out both the PowerShell
modules step and the Windows Update step on a 5.1 run.

### Do not assume elevation is possible

Lacking administrator rights and being forbidden to elevate are different
conditions, and policy can block the UAC prompt outright. There is a third:
winget has defaulted `Microsoft.PowerShell` to the MSIX package since 7.6, and
Windows will not run an MSIX-packaged process elevated at all — so a machine can
have a perfectly current `pwsh` that cannot self-elevate. `Test-PackagedProcess`
detects it and the run stops with a message naming which condition it hit and
what to do about it.

`Test-AdministratorGroupMember` is deliberately tri-state: yes, no, and *could
not determine*. A UAC filtered token drops `S-1-5-32-544` from the identity, so
a plain token check answers "not an administrator" for someone who is one.
Getting that question wrong in the permissive direction is the worst outcome
available, so uncertainty is returned as uncertainty rather than collapsed into
a false.

### Never bake a version-stamped path into anything durable

The MSIX package path carries the version, so it stops existing at the next
PowerShell update. A scheduled task holding that path silently stops working
weeks later. `Get-PowerShellHostPath` resolves a stable host instead.

### A run that asks a question is a run you can see

`Resolve-WindowStyle` overrides `Hidden` and `Minimized` to `Normal` when the
pre-run prompt is enabled, and says why. A prompt nobody can answer is a
scheduled task that hangs until its execution time limit kills it.

### Nothing in `src` calls `exit`

The module returns a result object. `exit` would end the session of whoever
called it. A test walks the AST of every file and fails on any
`ExitStatementAst`.

Only the scheduled task turns that result into an exit code, because a process
boundary is the one place where a number is all that can cross.

### Skipped is not failed

The summary has to distinguish "the tool is not installed" from "the tool is
installed and this went wrong", or the exit code means nothing.

Many command line tools write ordinary progress to stderr, so a step is marked
`Warning` only when PowerShell itself raised an error record.

### Never hard-code an excuse for a failure

An early version reported `uv` as OK on failure, explaining that this is
"expected when uv was installed via a package manager". The real cause was a
file lock, and the reassuring text hid it for several runs.

If a failure has a known benign cause, match the actual error text for it and
say which one you matched.

## Windows PowerShell 5.1 is a supported target

Not an afterthought. The module declares `CompatiblePSEditions = Desktop, Core`
and one of its jobs is installing PowerShell 7, so it must run correctly on
machines that do not have it yet.

Almost every bug in the MSIX branch was a 5.1 divergence that PowerShell 7 hid.
The differences that have actually bitten:

**Output encoding is not the same, and neither are the defaults.**
`Add-Content` defaults to ANSI on 5.1. `Tee-Object -FilePath` writes UTF-16LE
there with no `-Encoding` to override it. A step log written by both came out
half readable text and half interleaved nulls. Even `-Encoding utf8` diverges:
it means *with* BOM on 5.1 and *without* on 7. Write bytes explicitly —
`[System.IO.File]::AppendAllText` with a named encoding behaves the same on both
editions.

**`Write-Host` goes through the information stream on 5.1.** Inside an
`Invoke-Step` action, `*>&1` merges that into the pipeline, so a line was
written once by `Write-Host` and rendered again by `Out-Default`, and the
transcript recorded both. Inside a step action, write to the pipeline.
`Write-Host` is still right in the run summary, which is not inside a step and
uses colour to separate failures from noise.

**A module guard that reads `.OSVersion.Version` and then asks it for
`.Platform`** gets `$null`, and refuses to load — on 5.1 only. Every test passed,
because they all ran under 7 where a separate code path masked it.

Because of this, the suite shells out to both `powershell.exe` and `pwsh.exe`
and imports the module in each. If you change the loader, the manifest, or
anything touching encoding, run the suite on both editions before opening a PR.

## ErrorAction

The module never assigns `$ErrorActionPreference`. Setting it inside a module
changes the caller's session, which is not the module's to change, and it
converts every subsequent non-terminating error in that scope whether or not
that was intended.

Instead, `-ErrorAction Stop` goes on the individual call whose failure matters,
paired with `try`/`catch`. This is not decoration. `Register-ScheduledTask`
reports failure as a *non-terminating* error, so without `-ErrorAction Stop` the
code ran on and announced a successful registration that had not happened.

`-ErrorAction SilentlyContinue` is fine where a failure is genuinely
uninteresting: a cleanup that may find nothing, a probe of a key that may not
exist. An empty `catch {}` is not. Every catch says what it swallowed via
`Write-Verbose`, so `-Verbose` shows what was ignored.

The standalone scripts — `Install.ps1`, `Publish.ps1`, `test.ps1` — do set
`$ErrorActionPreference = 'Stop'` at the top. They own their session; the module
does not.

Logging is the exception to all of it. A failure to write a log must never be
the thing that kills a run, so `Write-StepLog` degrades to a warning rather than
propagating.

## Tests

Read [How the tests work](README.md#how-the-tests-work) first. It covers why the
suite never executes the module's actual work, why there is no coverage metric,
and why `Set-StrictMode` is deliberately absent.

### Conventions

Pester 6, and its assertion set: `Should-Be`, `Should-BeString`,
`Should-MatchString`, `Should-BeCollection`, `Should-ContainCollection`,
`Should-Invoke`, `Should-HaveParameter`. Pester 5's `Should -Be` pipeline form
does not run here.

Cases that vary only by data use `BeforeDiscovery` with `-ForEach`, so each is
reported as its own test rather than as one test that loops.

Tag every `Describe`. The suite uses `Static`, `Module`, `Docs`, `Unit`,
`Consent`, `Prompt`, `Notification` and `Lint`, and they are what make
`test.ps1 -Tag` and `-ExcludeTag` useful.

One logical assertion per `It`. `Should.ErrorAction` is left at its default of
`Stop`, so the first failure ends the test — which is what you want, because the
failure then names the thing that broke instead of its consequences.

Tests reach private functions by dot-sourcing `src/Private/*.ps1` and
`src/Public/*.ps1` individually rather than importing the module. File work goes
to `TestDrive`. Anything that reads the keyboard or waits on a clock is mocked —
`Read-TimedChoice` above all, because a test that waits on a countdown is a test
that hangs.

Run the suite the way CI does, so green locally means green in the pipeline:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\test.ps1
```

Linting is a tagged test inside the suite rather than a separate CI step, so
there is one source of truth about whether the code passes.

### Ways a test here has passed while the code was broken

Each of these produced a green suite over a real defect. Worth knowing before
you write an assertion, because none of them announce themselves.

**`$_` gets shadowed.** Inside `Where-Object`, `$_` is the pipeline element, not
the `-ForEach` item. A test iterating switch names and filtering AST nodes with
`Where-Object { $_.Name -eq $_ }` compares each node to itself and passes for
everything. Capture the item into a named variable first — `$switchName = $_` —
then filter on that. See `tests/Module.Tests.ps1`.

**PowerShell coerces the comparison and hides the mismatch.** `RandomDelay` on a
scheduled task trigger is an ISO 8601 string, and assigning a `[TimeSpan]` wrote
`00:15:00`, which Task Scheduler rejected. The test compared the property to a
`[TimeSpan]`, PowerShell coerced both sides, and it passed against the broken
value. Assert the type you actually expect: `Should-BeString 'PT15M'`.

**A regex that quietly requires something nobody writes.** A guard meant to
catch `.\script.ps1` in the README was written as `'^\s*\.\[A-Za-z]'`, one
backslash short, so it demanded a literal `[` and matched nothing — green, and
meaningless. Where a plain string operation will do, use one: `StartsWith('.\')`.

**Proximity assertions break on unrelated edits.** A test requiring two things
within N characters of each other failed the moment a suppression attribute was
inserted between them, which says nothing about the code. Bound the region
structurally instead: find the start of the branch, find the start of the next
branch, assert inside that substring.

**Commas inside method calls are argument separators.**
`[Console]::Write("..." -f $a, $b)` parses as `Write(("..." -f $a), $b)` and
throws. So does `$set.Add($x -replace 'a', 'b')`. Wrap the expression in its own
parentheses. The countdown redraw hit this, and the failure surfaced as
"unreadable keypress" — nowhere near the cause.

**`$Component?` is a variable name.** PowerShell reads the `?` as part of the
name, so `"Install $Component?"` rendered as `Install `. Write `${Component}`.

**A green suite is not proof the analyzer is happy.** The Gallery runs
PSScriptAnalyzer with its *default* rules, not this repository's tuned ones. The
tuned set showed nothing while the default set showed 70 findings. Deliberate
exceptions carry a `SuppressMessageAttribute` with a written justification, and
a test fails on any justification too short to be a reason, so this cannot decay
into blanket silencing.

A suppression that no longer applies is worse than none, because it describes
behaviour that is not there. Delete it with the code it described.

**Documentation drift needs testing in both directions.** A test that every
parameter is documented does not catch documentation for a parameter that no
longer exists. Assert both ways.

## Before opening a pull request

- `test.ps1` green, including the `Lint` tag.
- Green on both editions if you touched the loader, the manifest, or anything
  that writes a file.
- New parameters documented in the comment-based help *and* the README table.
  The suite fails until both exist.
- New behaviour tested through the AST or a mock, not by running it. If testing
  it requires elevating, installing, or rebooting, it is being tested wrong.
- No new `exit` in `src`, no `$ErrorActionPreference` in `src`, no empty
  `catch`.
- Commit messages say what changed and why, in the imperative, with the evidence
  where there is any — "Measured on 5.1: two occurrences before, one after" is
  worth more than an adjective. `git log` here is meant to read as a record of
  decisions.

## Publishing

Maintainers only, and not casually: the PowerShell Gallery has no delete, only
unlist, which hides a version from search while leaving it installable by anyone
who names it.

`Publish.ps1` front-loads every check before it sends anything, and `-WhatIf`
runs those checks and stops:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Publish.ps1 -WhatIf
```

It prompts for the API key rather than accepting it as an argument, so the key
stays out of shell history and out of any transcript.
