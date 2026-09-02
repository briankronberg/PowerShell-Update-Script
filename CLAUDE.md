# Working on UpdateEverything

**Read [CONTRIBUTING.md](CONTRIBUTING.md) before writing code.** It holds the
house style, the rules a change has to satisfy, the three places this repo
departs from convention and why, and the test conventions. This file covers only
what is not in there: how to set the machine up, and the traps that have
actually cost time.

## The gate

```powershell
.\test.ps1
```

One runner, used unchanged locally and in CI. It must be green, including the
`Lint` tag, before any claim that something works. `-Tag Static`, `-Tag Docs` and
`-Tag Lint` narrow it; `-CI` adds the non-zero exit code and `testResults.xml`.

Do not report a change as working on the strength of having written it. Run it.

## Setting up a machine

**Clone outside OneDrive.** OneDrive's Files On-Demand dehydrates files it thinks
are cold, and a dehydrated module tree is invisible to
`Get-Module -ListAvailable` — which presents as "Pester 6 is not installed" on a
machine where it is. `C:\Users\<you>\source\repos` is fine.

```powershell
Install-Module Pester -MinimumVersion 6.0.0 -Scope CurrentUser -Force -SkipPublisherCheck
Install-Module PSScriptAnalyzer -Scope CurrentUser
```

**Pester 6, not 5.** This matters more than it sounds, because Pester 5 syntax is
the reflex and it fails in a confusing way. The pipeline form is gone:

```powershell
$x | Should -Be 'y'      # Pester 5. Does not work here.
$x | Should-Be 'y'       # Pester 6. Note the hyphen.
```

The assertions this suite uses, all of which exist:

`Should-Be` `Should-BeNull` `Should-BeTrue` `Should-BeFalse` `Should-MatchString`
`Should-NotMatchString` `Should-BeCollection` `Should-ContainCollection`
`Should-NotBeNull` `Should-BeGreaterThan` `Should-BeGreaterThanOrEqual`
`Should-BeLessThan` `Should-Throw` `Should-HaveType` `Should-HaveParameter`
`Should-BeString` `Should-NotBeString` `Should-NotBeEmptyString` `Should-All`
`Should-Invoke` `Should-NotInvoke`

`Should-BeOfType` and `Should-NotBeNullOrEmpty` do **not** exist in Pester 6.
Reach for `Should-HaveType` and `Should-NotBeEmptyString`.

There is no `Should-NotThrow` either — only `Should-Throw`. To assert that
something does not throw, call it and assert on what it returned; a test that
inspects the result has already proved it.

Check a name before reaching for it rather than after:

```powershell
(Get-Command -Module Pester -Name 'Should-*').Name
```

**PowerShell 7 from the MSI, not the Store.** The MSIX build cannot be elevated,
cannot use in-process COM (the DISM cmdlets fail with "Class not registered"),
and its path carries a version stamp that a scheduled task cannot rely on. The
module has code specifically about this, so testing it needs the MSI:

```powershell
winget install --id Microsoft.PowerShell --exact --source winget --installer-type wix
```

Both builds can coexist. `dism.exe` works from either, being a separate process.

## Traps that have cost time here

**PowerShell's location is not the process working directory.** `[System.IO.File]`
methods resolve relative paths against the process CWD, which is often not where
`Get-Location` says you are. Pass absolute paths to .NET methods.

**Comment-based help ends at any line starting with a dot.** A line whose first
non-space character is a dot is read as a help keyword, whatever word follows, so
a wrapped `.NET global tools` silently discards every help section after it.
`Get-Help` reports no error, it just returns empty. Write `dotnet`. A test now
catches this.

**Windows PowerShell writes UTF-16LE where 7 writes UTF-8.** `Tee-Object` has no
`-Encoding` on 5.1, and `Add-Content -Encoding utf8` means "with BOM" on 5.1 and
"without" on 7. Use `[System.IO.File]::AppendAllText` with an explicit
`UTF8Encoding($false)` — `Write-StepLog` is the pattern.

**Unassigned pipeline output inside a function is the return value.** A bare
`$table | Format-Table` in a function returns formatting objects to the caller
instead of displaying them. `Out-Host` is the fix, and the reason it appears in
`Invoke-Step` and the summary.

**Verify with tools that fail loudly.** `Edit` errors when its target string does
not match; a `.Replace()` that near-misses silently does nothing and leaves you
believing an edit landed. `git stash push -- <untracked-path>` errors on the
pathspec and stashes nothing, which has produced a "passing" verification against
unchanged code.

Do not filter command output in a way that could hide the error you are looking
for. A `-notmatch` on an expected-noise phrase has swallowed the actual failure.

## Publishing

The full procedure is in [CONTRIBUTING.md](CONTRIBUTING.md#publishing). The parts
worth knowing before touching anything release-shaped:

- The gallery has no delete, only unlist. A published version is permanent.
- `Publish.ps1 -WhatIf` runs every check and sends nothing. It is the real gate.
- PSScriptAnalyzer must be clean over `src` under its **default** rules, not this
  repo's tuned settings file. The default rules are what the gallery displays.
- `PrivateData.PSData.ReleaseNotes` is the package page. It ships permanently
  with the version, so it describes that version.

## Tracking

Work lives in [issues](https://github.com/briankronberg/UpdateEverything/issues).
Feature requests and bugs both, separated by label rather than location. The
[1.1.0 milestone](https://github.com/briankronberg/UpdateEverything/milestone/1)
holds what is committed to the next version; anything without a milestone is
backlog. Issue #25 carries the roadmap and its dependency order.

Close issues from the pull request body with `Closes #N`, so the record maintains
itself.

## Agent skills

### Issue tracker

Issues are tracked as GitHub issues on briankronberg/UpdateEverything via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five default labels, each string equal to its role name (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
