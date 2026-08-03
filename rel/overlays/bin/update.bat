@echo off
REM SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0
REM Checks or applies a signed standalone Cartulary release update.
setlocal
set "RELEASE_ROOT=%~dp0.."
if "%~1"=="" goto check
if "%~1"=="--check" goto check
if "%~1"=="--auto" goto auto
if "%~1"=="--version" goto version
echo usage: bin\update.bat [--check ^| --auto ^| --version MAJOR.MINOR.PATCH] 1>&2
exit /b 64

:check
call "%~dp0cartulary.bat" eval "IO.inspect(Cartulary.Update.check())"
exit /b %ERRORLEVEL%

:auto
call "%~dp0cartulary.bat" eval "case Cartulary.Update.check() do %%{automatic_eligible: true, available_version: version} -> Cartulary.Update.apply!(version); result -> IO.inspect(result) end"
exit /b %ERRORLEVEL%

:version
if "%~2"=="" exit /b 64
call "%~dp0cartulary.bat" eval "Cartulary.Update.apply!(\"%~2\")"
exit /b %ERRORLEVEL%
