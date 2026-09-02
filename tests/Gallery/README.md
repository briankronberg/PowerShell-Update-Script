# Gallery validation

Downloads a published version from the PowerShell Gallery and runs it, so the
artifact people install is the artifact that was checked.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Gallery\Invoke-GalleryValidation.ps1
```

Run it after every publish, once the gallery lists the new version. It is not
part of `test.ps1`: it needs the network, and it validates a published
artifact rather than the working tree.

## Why it exists

Nothing else touches the `.nupkg` the gallery serves. The suite tests the
working tree, CI tests the repository, and the fresh-machine harness installs
from GitHub `main` — a packaging defect in the published artifact would pass
all three.

## The identity check is the point

In a fresh session, a bare `Update-Everything` auto-loads whichever copy
`PSModulePath` resolves — not the one just downloaded. The first ad-hoc
validation of 1.4.0 hit exactly this: the machine carried a stale installed
1.2.1, the run reported `UpdateEverything 1.2.1` with the old step set, and
every check came back green against the wrong code. The harness therefore
proves `(Get-Module UpdateEverything).ModuleBase` is inside the downloaded
folder before asserting anything else.

## What it checks

- The gallery serves the requested version and the manifest validates with
  the six exports
- The loaded module is the downloaded copy, at the requested version
- `-Tag Inventory` (read-only) runs: the banner names the version, the
  Inventory step is `OK`, every other step is `Skipped`, and `FailedCount`
  is zero

## What it changes

Nothing, by default: the download goes to a temporary folder that is removed
afterwards, and Inventory only reads.

`-IncludeSelfUpdate` adds a live `Update-Everything -UpdateSelf` pass and
asserts the self step is the only one that runs. That pass updates the host's
installed UpdateEverything when one is present and behind — which is the
behaviour under test, so it is opt-in.
