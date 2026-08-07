# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0
#
# Windows packaged-release verification: build the Windows package, boot its
# embedded pg0 from an empty data root, wait for readiness, then run the full
# suite against that database. This is the Windows counterpart of ci-pg0-lane.
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$LaneRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("memhouse-f11-pg0-" + [guid]::NewGuid())
$ReleaseRoot = Join-Path $RepoRoot "_build\prod\rel\memhouse"
$ReleaseLog = Join-Path $LaneRoot "release.log"
$ReleaseErrorLog = Join-Path $LaneRoot "release-error.log"
$ReleaseProcess = $null
$Succeeded = $false

New-Item -ItemType Directory -Force $LaneRoot | Out-Null

try {
  & (Join-Path $RepoRoot "scripts\package-release.ps1")

  $env:CARTULARY_AUTH_SIGNING_SECRET = "memhouse-f11-ci-only-signing-secret-that-is-longer-than-sixty-four-bytes"
  $env:CARTULARY_AUTO_MIGRATE = "true"
  $env:CARTULARY_DATABASE_MODE = "pg0"
  $env:CARTULARY_DATA_ROOT = (Join-Path $LaneRoot "data")
  $env:CARTULARY_PG0_NAME = "memhouse-f11-ci"
  $env:CARTULARY_PG0_PORT = "55431"
  $env:DATABASE_URL = ""
  $env:PORT = "4101"
  $env:PHX_HOST = "127.0.0.1"

  $Server = Join-Path $ReleaseRoot "bin\server.bat"
  $ReleaseProcess = Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", ('"{0}"' -f $Server)) -PassThru `
    -RedirectStandardOutput $ReleaseLog -RedirectStandardError $ReleaseErrorLog

  $Ready = $false
  for ($Attempt = 0; $Attempt -lt 60; $Attempt++) {
    try {
      $Response = Invoke-WebRequest -Uri "http://127.0.0.1:4101/api/ready" -UseBasicParsing
      if ($Response.StatusCode -eq 200) {
        $Ready = $true
        break
      }
    }
    catch {
      # A cold pg0 cluster is expected to return no response until initialization completes.
    }

    Start-Sleep -Seconds 1
  }

  if (-not $Ready) {
    throw "Packaged Windows release did not become ready within 60 seconds"
  }

  $env:CARTULARY_DATABASE_MODE = "external"
  $env:CARTULARY_TEST_DATABASE_URL = "ecto://postgres:postgres@127.0.0.1:55431/cartulary_f11_pg0"
  $env:MIX_ENV = "test"
  Push-Location $RepoRoot
  try {
    mix test
    if ($LASTEXITCODE -ne 0) { throw "mix test failed" }
  }
  finally {
    Pop-Location
  }

  $Succeeded = $true
}
finally {
  if (Test-Path (Join-Path $ReleaseRoot "bin\memhouse.bat")) {
    try {
      & (Join-Path $ReleaseRoot "bin\memhouse.bat") stop | Out-Null
    }
    catch {
      # The process may have failed before the release launcher accepted commands.
    }
  }

  if ($ReleaseProcess -and -not $ReleaseProcess.HasExited) {
    Stop-Process -Id $ReleaseProcess.Id -Force -ErrorAction SilentlyContinue
  }

  if (-not $Succeeded -and (Test-Path $ReleaseLog)) {
    Get-Content $ReleaseLog -TotalCount 240
  }

  if (-not $Succeeded -and (Test-Path $ReleaseErrorLog)) {
    Get-Content $ReleaseErrorLog -TotalCount 240
  }

  Remove-Item -Recurse -Force $LaneRoot -ErrorAction SilentlyContinue
}
