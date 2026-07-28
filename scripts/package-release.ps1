# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Version = (Get-Content (Join-Path $RepoRoot "rel\pg0\VERSION") -Raw).Trim()
$Asset = "pg0-windows-x86_64.exe"
$Overlay = Join-Path $RepoRoot "rel\overlays\bin\pg0.exe"
$Checksums = Join-Path $RepoRoot "rel\pg0\checksums.txt"
$Expected = ((Get-Content $Checksums | Where-Object { $_ -match "\s+$([regex]::Escape($Asset))$" }) -split "\s+")[0]

if (-not $Expected) {
  throw "No pinned checksum found for $Asset"
}

New-Item -ItemType Directory -Force (Split-Path $Overlay) | Out-Null

try {
  Invoke-WebRequest `
    -Uri "https://github.com/vectorize-io/pg0/releases/download/v$Version/$Asset" `
    -OutFile $Overlay

  $Actual = (Get-FileHash -Algorithm SHA256 $Overlay).Hash.ToLowerInvariant()

  if ($Actual -ne $Expected) {
    throw "pg0 checksum mismatch for $Asset"
  }

  Push-Location $RepoRoot
  $env:MIX_ENV = "prod"
  mix deps.get --only prod
  if ($LASTEXITCODE -ne 0) { throw "mix deps.get failed" }
  mix release --overwrite
  if ($LASTEXITCODE -ne 0) { throw "mix release failed" }
  Pop-Location
}
finally {
  if (Test-Path $Overlay) {
    Remove-Item -Force $Overlay
  }
}

Write-Output "Release ready at $RepoRoot\_build\prod\rel\cartulary"
