@echo off
REM The production deploy is update-prod.ps1, next to this file. This wrapper
REM only forwards its arguments, so the old habit of running update-prod.bat
REM keeps working:
REM   update-prod.bat -Tag 99e86008 -Backup              (backup, then rehearse on the Mac)
REM   update-prod.bat -Tag 99e86008 -Deploy -Rehearsed   (only after a GREEN rehearsal)
REM   update-prod.bat -Tag 98ea5220 -Deploy -Rollback    (back to the previous release)
REM Registry login is no longer here: run "docker login registry.gitlab.com" once.
REM See docs/runbooks/release-rehearsal.md.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-prod.ps1" %*
exit /b %ERRORLEVEL%
