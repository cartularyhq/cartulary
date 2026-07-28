# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0
#
# Windows counterpart of scripts/package-release: build the self-contained Mix
# release with the pinned embedded PostgreSQL launcher (pg0) staged inside it.
#
# Purpose
#   Produce a release that runs on a Windows host with no PostgreSQL installed;
#   rel\overlays\bin\server.bat starts a private database managed by the release
#   itself. The same release also runs against an operator-run PostgreSQL, which
#   is a runtime choice, not a different build.
#
# Arguments
#   None.
#
# Environment
#   Nothing is required. MIX_ENV is set to "prod" for the build below. Network
#   access is required to fetch the pg0 asset. Only the x86_64 Windows asset is
#   published, so there is no platform detection here.
#
# Outputs
#   _build\prod\rel\cartulary — the unpacked release.
#
# Failure behaviour
#   $ErrorActionPreference = "Stop" turns cmdlet errors into terminating errors,
#   and each external `mix` call is checked through $LASTEXITCODE because native
#   process exit codes do not raise on their own. A missing pin, a failed
#   download, or a checksum mismatch throws. The finally block always deletes
#   the downloaded binary, so an unverified executable is never left in the
#   working copy.
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
# pg0 is pinned twice: by the exact version string in rel\pg0\VERSION and by a
# per-platform SHA-256 in rel\pg0\checksums.txt. A version tag alone can be
# repointed upstream, so the digest is the real guarantee that the database
# engine underneath every durable write is the reviewed one. Changing pg0 means
# updating VERSION and every digest together in one reviewed change.
$Version = (Get-Content (Join-Path $RepoRoot "rel\pg0\VERSION") -Raw).Trim()
$Asset = "pg0-windows-x86_64.exe"
# rel\overlays is copied verbatim into the release, so this path becomes
# bin\pg0.exe inside the packaged release — where the runtime configuration
# looks for the database engine by default.
$Overlay = Join-Path $RepoRoot "rel\overlays\bin\pg0.exe"
$Checksums = Join-Path $RepoRoot "rel\pg0\checksums.txt"
# Each entry is "<sha256>  <asset>". Anchoring on the asset name at end-of-line
# keeps a longer asset name that merely starts the same from matching, and lets
# the file's header comment lines fall through, since they do not end in an
# asset name. Escape the name because ".exe" would otherwise let "." match any
# character.
$Expected = ((Get-Content $Checksums | Where-Object { $_ -match "\s+$([regex]::Escape($Asset))$" }) -split "\s+")[0]

# Refuse to build rather than fetch an unpinned binary: an empty $Expected would
# otherwise make the comparison below meaningless.
if (-not $Expected) {
  throw "No pinned checksum found for $Asset"
}

New-Item -ItemType Directory -Force (Split-Path $Overlay) | Out-Null

try {
  Invoke-WebRequest `
    -Uri "https://github.com/vectorize-io/pg0/releases/download/v$Version/$Asset" `
    -OutFile $Overlay

  # Get-FileHash returns uppercase hex; the pinned digests are lowercase, so
  # normalise before comparing or every build would look tampered with.
  $Actual = (Get-FileHash -Algorithm SHA256 $Overlay).Hash.ToLowerInvariant()

  # Verify before `mix release` copies the binary into the release. A mismatch
  # means the pin and the fetched bytes disagree. Never resolve it by pasting
  # the computed hash into checksums.txt — that would make the pin verify
  # whatever happened to download and remove the supply-chain check entirely.
  if ($Actual -ne $Expected) {
    throw "pg0 checksum mismatch for $Asset"
  }

  Push-Location $RepoRoot
  $env:MIX_ENV = "prod"
  # --only prod keeps dev/test-only dependencies out of the shipped release.
  mix deps.get --only prod
  if ($LASTEXITCODE -ne 0) { throw "mix deps.get failed" }
  # --overwrite replaces a previously unpacked release instead of aborting.
  mix release --overwrite
  if ($LASTEXITCODE -ne 0) { throw "mix release failed" }
  Pop-Location
}
finally {
  # Always remove the staged binary, including after a throw above. It is a
  # build input rather than a tracked source file; leaving it behind would let a
  # later run ship bytes that were never re-verified.
  if (Test-Path $Overlay) {
    Remove-Item -Force $Overlay
  }
}

Write-Output "Release ready at $RepoRoot\_build\prod\rel\cartulary"
