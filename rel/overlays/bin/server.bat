@echo off
REM SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0
setlocal
if "%CARTULARY_DATA_ROOT%"=="" set CARTULARY_DATA_ROOT=%USERPROFILE%\.cartulary
if not exist "%CARTULARY_DATA_ROOT%" mkdir "%CARTULARY_DATA_ROOT%"
if "%CARTULARY_AUTH_SIGNING_SECRET%"=="" (
  if not exist "%CARTULARY_DATA_ROOT%\auth-signing-secret" (
    powershell -NoProfile -Command "$b=New-Object byte[] 48;[Security.Cryptography.RandomNumberGenerator]::Fill($b);[Convert]::ToBase64String($b)|Set-Content -NoNewline '%CARTULARY_DATA_ROOT%\auth-signing-secret'"
  )
  set /p CARTULARY_AUTH_SIGNING_SECRET=<"%CARTULARY_DATA_ROOT%\auth-signing-secret"
)
if "%CARTULARY_DATABASE_MODE%"=="" set CARTULARY_DATABASE_MODE=pg0
if "%CARTULARY_AUTO_MIGRATE%"=="" set CARTULARY_AUTO_MIGRATE=true
if "%CARTULARY_PG0_BINARY%"=="" set CARTULARY_PG0_BINARY=%~dp0pg0.exe
if "%CARTULARY_PG0_DATA_DIR%"=="" set CARTULARY_PG0_DATA_DIR=%CARTULARY_DATA_ROOT%\pg0\instances\cartulary\data
if "%CARTULARY_BLOB_ROOT%"=="" set CARTULARY_BLOB_ROOT=%CARTULARY_DATA_ROOT%\blobs
set PHX_SERVER=true
call "%~dp0cartulary.bat" start
