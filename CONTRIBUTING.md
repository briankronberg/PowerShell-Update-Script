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

### Nothing the loader dot-sources calls `exit`

The module returns a result object. `exit` would end the session of whoever
called it. A test walks the AST of every file under `Public` and `Private`
and fails on any `ExitStatementAst`.

The one file in `src` outside those folders, `Convert-PowerShell7ToMsi.ps1`,
does call `exit`, on purpose: it is a standalone script the module ships but
never dot-sources, run only in its own process via `-File`, where an explicit
exit code is the contract.

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

## House style

General PowerShell practice, adopted here. Most of it this codebase already
followed; the interesting part is the three rules it deliberately does not, and
why. Where a rule below is enforced by a test or the analyzer, that is said —
the rest are read by eye at review.

### Adopted as written

**No aliases.** `Get-ChildItem`, not `dir` or `gci`. `Where-Object`, not
`where` or `?`. Aliases can be redefined, differ between editions, and read as
noise to anyone who has not memorised them. *Enforced:* PSScriptAnalyzer flags
`PSAvoidUsingCmdletAliases` under both this repository's settings and the
default rules.

**Approved verbs, in `Verb-Noun` form.** Check with `Get-Verb` before inventing
one. *Enforced:* `PSUseApprovedVerbs`.

**Splat past three parameters.** A hash table splat reads down the page instead
of across it, and diffs one line per change rather than rewriting a backtick
continuation. `Register-ScheduledTask` and `Install-Module` are already called
this way.

**Declare parameter types.** `[string]`, `[int]`, `[switch]`, `[string[]]`.
`ValidateSet` and `ValidateRange` where the set is closed, so a typo is an
error at bind time rather than a silent full run — `-Tag Pyhton` matching
nothing is the failure this prevents.

**Return objects, not text.** `[pscustomobject]` with named properties, so a
caller can filter and sort without parsing. `New-UpdateEverythingResult` is the
example; it derives its counts from the step records so the two cannot
disagree.

**Comment-based help on every public function**, with `.SYNOPSIS`,
`.DESCRIPTION`, `.PARAMETER` for each parameter, and at least one `.EXAMPLE`.
*Enforced:* a test asserts every parameter is documented, and that nothing is
documented that no longer exists.

### Comments

**A comment states a fact about the code, not the story of how it got there.**
The reader is whoever changes this file next year, and what helps them is the
constraint that is still true: the API that returns `$null`, the exit code that
means "nothing to do", the parser rule that forces two statements apart. How
that constraint came to be known does not help them.

So: no version history (`used to`, `an earlier draft`, `they now rotate`), no
narration of a debugging session or a review discussion, no measurements taken
on one machine on one day, and no second person. Git holds that already, and a
comment repeating it goes stale the moment the code moves.

```powershell
# Wrong -- narrates a debugging session
# Counting every entry made a single leftover DEL396A.tmp announce a pending
# reboot on every run, while CBS and Windows Update both reported nothing.

# Right -- states what is true
# A pair with an empty destination is a scheduled deletion, which installers
# queue constantly for their own temp files and which needs no restart.
```

Explaining *why* is still in scope and is often the only thing worth writing.
A "why" that is a property of Windows, of PowerShell, or of a tool's contract
is a fact. A "why" that is a property of a past pull request is not.

**Never start a line inside a help block with a dot.** A line whose first
non-space character is a dot is read as a help keyword, whatever word follows
it. A wrapped `.NET global tools` ends the section it sits in and discards every
section after it — `Get-Help` reports no error, it just returns an empty
description. Write `dotnet`, or reflow the line. *Enforced:* a test scans every
`<# #>` block for a leading dot that is not a real keyword.

### Adopted with a documented exception

These three are good general advice and wrong for parts of this module. The
exceptions are narrow, and each has a reason that cost something to learn.

**`$ErrorActionPreference = 'Stop'` — scripts yes, the module never.** See
[ErrorAction](#erroraction). Setting it inside a module changes the caller's
session, which is not the module's to change. `Install.ps1`, `Publish.ps1` and
`test.ps1` do set it, because they own their session. The pre-PR checklist
rejects it in `src`.

`Invoke-Step` is the one exception, and it runs the other way: it sets
`Continue`, **function-locally**, before invoking a step action. A caller who
prefers `Stop` makes a native command's stderr terminating, and these steps drive
tools that write to stderr as a matter of course — npm its deprecation notices,
winget its progress, `wsl` its "not installed" message. Each such step then threw
before reaching the exit-code check written to handle precisely that, so the
run's result depended on a preference set outside it. A function-local assignment
cannot reach the caller's session, which is what the rule protects; a `global:`
or `script:` one can, and a separate test rejects those everywhere including
there.

**`Set-StrictMode -Version Latest` — not in the module.** It makes reading a
missing property fatal, and the module has to probe for optional keys in
Windows Terminal's `settings.json`, where they are frequently absent. Turning
it on would break the path it exists to handle. A test recovers the useful half
instead, walking the AST and failing if a function reads a variable it never
assigns.

**`Write-Host` — never for data, and never inside a step action.** The general
rule is right about data: anything a caller might consume goes to the pipeline.
But this is a console maintenance tool whose progress is watched by a person,
and colour separates a failure from noise, so the summary uses `Write-Host`
deliberately and says so in a `SuppressMessageAttribute`.

The sharper rule is about *where*. Inside an `Invoke-Step` action, `*>&1`
merges the information stream into the pipeline, so on Windows PowerShell every
`Write-Host` line is written once to the console and rendered again by
`Out-Default` — measured at two occurrences in the transcript, one wrapped to
console width and one not. Helpers called from a step use `Write-Output`;
`Update-Everything`'s own summary, which is not inside a step, uses
`Write-Host`. *Enforced:* a test asserts the Terminal helper contains no
`Write-Host` call.

`Write-Verbose`, `Write-Warning` and `Write-Error` are for the streams they
name, in either case.

### Error boundaries

`try`/`catch` around the call whose failure matters, with `-ErrorAction Stop`
on that call — not a blanket preference. The step runner is the outer boundary:
`Invoke-Step` catches per step, records the outcome, and lets the run continue,
because one dead package manager must not stop the other twelve. An empty
`catch {}` is rejected; every catch says what it swallowed through
`Write-Verbose`.

### The template

A public function looks like this. `begin`/`process`/`end` are for functions
that genuinely accept pipeline input — most here do not, and an empty
`process` block around a single call is noise.

```powershell
<#
    .SYNOPSIS
    One line, in the imperative.

    .DESCRIPTION
    What it does, what it assumes, and why it is shaped this way. This is where
    a decision that cost an afternoon gets written down.

    .PARAMETER Name
    What it selects, and what happens when it is omitted.

    .EXAMPLE
    Get-Thing -Name 'widget'
#>
function Get-Thing {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name
    )

    try {
        $raw = Get-Content -LiteralPath $Name -Raw -ErrorAction Stop
    } catch {
        # The inner exception, not a generic message: "could not read the file"
        # sends someone looking in the wrong place.
        throw "Could not read '$Name': $($_.Exception.Message)"
    }

    [pscustomobject]@{
        Name   = $Name
        Length = $raw.Length
    }
}
```

Note `Mandatory` with no value rather than `Mandatory = $true`. Both work;
`Mandatory = true` does not — an unquoted bareword there is a parse error, and
the function will not load at all.

### Before writing

1. **Say what it changes.** If it writes to the registry, installs software,
   registers a task or can reboot, say so before the code. Anything that
   installs needs the consent gate; see [Updating is not
   installing](#updating-is-not-installing).
2. **Write the parameter block and the help first.** They are the contract, and
   the suite checks both directions of it.
3. **Then the body**, commented where the reason is not obvious from the code.
4. **Say how it was validated.** Which tests, run how, and — for anything that
   cannot be unit tested — what was measured and on which edition. "Measured on
   5.1: two occurrences before, one after" belongs in the commit message.

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
and imports the module in each, and CI runs a second job that takes the
read-only inventory pass end to end under 5.1
(`tests/WindowsPowerShell/Invoke-WindowsPowerShellSmoke.ps1`, runnable locally
with `powershell -File`). If you change the loader, the manifest, or anything
touching encoding, run that smoke test as well as the suite before opening a
PR -- the suite itself cannot run under 5.1, because Pester 6 requires 7.

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

The standalone scripts — `Install.ps1`, `Publish.ps1`, `test.ps1`, and the
shipped `src\Convert-PowerShell7ToMsi.ps1` — do set
`$ErrorActionPreference = 'Stop'` at the top. Each owns its session: the mover
runs only in its own process via `-File`, never dot-sourced by the loader. The
module itself does not set it.

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
`Consent`, `Prompt`, `Notification`, `Lint` and `Integration`, and they are what
make `test.ps1 -Tag` and `-ExcludeTag` useful.

One logical assertion per `It`. `Should.ErrorAction` is left at its default of
`Stop`, so the first failure ends the test — which is what you want, because the
failure then names the thing that broke instead of its consequences.

Tests reach private functions by dot-sourcing `src/Private/*.ps1` and
`src/Public/*.ps1` individually rather than importing the module. File work goes
to `TestDrive`. Anything that reads the keyboard or waits on a clock is mocked —
`Read-TimedChoice` above all, because a test that waits on a countdown is a test
that hangs. The two exceptions are deliberate and bounded: the tests whose
subject is the countdown itself run the real one, with two- and three-second
timeouts, because a mocked clock would prove nothing about the redraw and the
timeout they exist to pin.

Run the suite the way CI does, so green locally means green in the pipeline:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\test.ps1
```

Linting is a tagged test inside the suite rather than a separate CI step, so
there is one source of truth about whether the code passes.

### Where the time goes

Two costs dominate the suite, and neither is a defect nor worth optimising:

| Cost | What it is |
|---|---|
| The first `Invoke-ScriptAnalyzer` call in a process | Loading the rule assemblies is the entire expense, tens of seconds; every call after it is milliseconds. Batching the calls does not help, because the number of calls is not what costs. Every analyzer pass carries the `Lint` tag, including the gallery-readiness test. |
| The `Integration` tests | They register and remove real scheduled tasks, seconds per task against the real Task Scheduler, and there is nothing between the test and that price. |

While iterating, skip both; the rest of the suite finishes in well under a
minute:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\test.ps1 -ExcludeTag Lint,Integration
```

Run the whole thing before opening a PR. CI runs it either way.

A test that registers a real task should register it once and assert several
times, in a `Context` with the registration in `BeforeAll`. Two tests that each
register the same cadence pay the full 6.6s twice for the same task.

### Measuring coverage

There is no coverage gate, and `test.ps1` never measures it: `Update-Everything`
itself is tested statically, so its commands can never execute under the suite,
and a percentage target would either fail forever or pressure a test into
running code that elevates, installs and reboots.

The map is still worth drawing when hunting for untested branches:

```powershell
$config = New-PesterConfiguration
$config.Run.Path             = '.\tests'
$config.CodeCoverage.Enabled = $true
$config.CodeCoverage.Path    = '.\src'
Invoke-Pester -Configuration $config
```

Read the per-file numbers, not the total. Dark on purpose: `Update-Everything.ps1`
(static-tested), `Request-InstallConsent` and `Read-TimedChoice`'s wait loop
(both need a real console host), `Invoke-SelfElevation`'s relaunch (the attended
elevation harness exercises it live), and the psm1's platform guards. A gap
anywhere else is a finding — #93 and #94 each came from exactly this reading.

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
  The one exception is tagged `Integration`, and it exists because a mock cannot
  catch a defect that lives *between* two things: `-Cadence PatchTuesday` shipped
  in 1.0.0 unable to register a task at all, while the unit test asserting the
  trigger object's properties passed, because nothing handed that object to
  `Register-ScheduledTask`. Reach for this only when the failure is provably
  invisible from either side, and leave the test able to skip when it cannot run.
- No new `exit` and no `$ErrorActionPreference` in anything the loader
  dot-sources. The shipped mover script sets and owns both, in its own
  process. No empty `catch`.
- Comments state facts about the code, not its history. The story of the change
  belongs in the commit message and the pull request, where it stays accurate.
- Commit messages say what changed and why, in the imperative, with the evidence
  where there is any — "Measured on 5.1: two occurrences before, one after" is
  worth more than an adjective. `git log` here is meant to read as a record of
  decisions, which is why the code does not have to be.

## Publishing

Maintainers only, and not casually: the PowerShell Gallery has no delete, only
unlist, which hides a version from search while leaving it installable by anyone
who names it.

### Minor versions reach the gallery; a patch only when it earns it

Minor versions are published. Patch versions usually are not, and live on
`main` for whoever wants them. The exception is a patch that changes what an
installed copy does on its next run -- 1.7.1, whose fix decides where a
self-update lands, set the precedent:

| Version | Where |
|---|---|
| 1.2.0, 1.3.0, 1.4.0 | PowerShell Gallery, and GitHub |
| 1.2.1, 1.2.2 | GitHub only |
| 1.7.1, 1.7.2, 1.7.3 | PowerShell Gallery, and GitHub |

Every gallery version is permanent -- unlist hides it from search and leaves it
installable -- so each one is a commitment, and fewer of them means fewer to
stand behind.

Two things follow, and both are already handled rather than needing thought at
release time:

A patch fix reaches people through the GitHub install, so the README's
**Install from GitHub** section is not a footnote. It is the supported route to
anything not yet in a minor release, and it says so.

`Update-Everything -UpdateSelf` defaults to `-UpdateSelfSource Gallery`, which is
right for most people and wrong for anyone tracking a fix. `Main` is the setting
for that, and the help says which is which.

A run reports both, so nobody has to work it out:

```
UpdateEverything 1.2.1 is running, ahead of the published 1.2.0.
```

`Publish.ps1` front-loads every check before it sends anything, and `-WhatIf`
runs those checks and stops:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Publish.ps1 -WhatIf
```

It prompts for the API key rather than accepting it as an argument, so the key
stays out of shell history and out of any transcript.

Before publishing:

- Raise `ModuleVersion` in the manifest. A version already on the gallery cannot
  be replaced, and `Publish.ps1` refuses one that is not newer.
- Rewrite `PrivateData.PSData.ReleaseNotes` to describe *this* version. It is the
  package page, and it is as permanent as the version it ships with.
- Run the [fresh-machine smoke test](tests/FreshMachine/README.md). It is not
  part of `test.ps1`, it needs a hypervisor and several minutes, and it belongs
  before a release rather than before a commit.
- Run the [self-elevation test](tests/Elevation/README.md) if the release touches
  elevation. It needs one click on a UAC prompt, which is why it is not in
  `test.ps1` either, and it covers the one path the fresh-machine test reports
  `N/A` for.

Afterwards, tag the exact commit that was published, so the permanent version
has something in the history pointing at it:

```bash
git tag -a v1.9.0 -m "1.9.0" && git push origin v1.9.0
```

Then cut a GitHub release at that tag, reusing the manifest's `ReleaseNotes` so
one text serves the manifest, the gallery page and the release.

Once the gallery lists the new version, run the
[gallery validation](tests/Gallery/README.md). It downloads the published
artifact and runs it, which nothing before the publish can do.
