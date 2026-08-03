@echo off
REM SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0
REM Applies packaged-release migrations without starting Phoenix.
setlocal
set "RELEASE_ROOT=%~dp0.."
call "%~dp0cartulary.bat" eval "Cartulary.Release.migrate()"
exit /b %ERRORLEVEL%
