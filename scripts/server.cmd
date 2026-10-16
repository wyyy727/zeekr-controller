@echo off
setlocal enabledelayedexpansion

REM ================================================================
REM  ZeekrDash service manager (Windows native)
REM
REM  Usage (from any directory, or just double-click this file):
REM      scripts\server.cmd start|stop|restart|status|logs
REM      scripts\server.cmd            - show status + usage
REM
REM  This is the Windows counterpart of scripts\server.sh.
REM  Same features, two platforms. If you change one, change the
REM  other too - especially the port lookup and the stop logic,
REM  those are the easiest to drift apart.
REM
REM  Why this file exists:
REM  .sh has no executable meaning on Windows. Double-clicking it,
REM  or running it from CMD, makes Windows open a THROWAWAY Git Bash
REM  window through the file association. The window closes the
REM  instant the script returns, so it looks like a flash and every
REM  bit of output is lost.
REM
REM  NOTE: keep this file ASCII-only.
REM  cmd.exe parses the script bytes using the console's ANSI code
REM  page (GBK/936 on a Chinese Windows), not UTF-8. Non-ASCII text
REM  here gets mis-decoded and corrupts the surrounding commands.
REM  That is also why the log is read with `type` and no chcp dance.
REM ================================================================

set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\server") do set "SERVER_DIR=%%~fI"
for %%I in ("%SCRIPT_DIR%..") do set "REPO_DIR=%%~fI"
set "PID_FILE=%SERVER_DIR%\.server.pid"
set "LOG_FILE=%SERVER_DIR%\.server.log"

set "HOST=0.0.0.0"
set "PORT=8765"

REM ---- read .env -------------------------------------------------
REM Lookup order matches server.sh and app/core/config.py:
REM   server\.env  then  <repo>\.env   (first hit wins)
if exist "%SERVER_DIR%\.env" (
  for /f "usebackq eol=# tokens=1,* delims==" %%A in ("%SERVER_DIR%\.env") do (
    if /i "%%A"=="APP_HOST" set "HOST=%%B"
    if /i "%%A"=="APP_PORT" set "PORT=%%B"
  )
) else if exist "%REPO_DIR%\.env" (
  for /f "usebackq eol=# tokens=1,* delims==" %%A in ("%REPO_DIR%\.env") do (
    if /i "%%A"=="APP_HOST" set "HOST=%%B"
    if /i "%%A"=="APP_PORT" set "PORT=%%B"
  )
)

REM ---- dispatch ---------------------------------------------------
REM No argument (i.e. a double-click) means: just run it in THIS window
REM and let the log scroll right here. That is the most direct thing a
REM user can want, so it gets the default slot - no extra command,
REM no separate window, nothing to remember.
if /i "%~1"=="start"   goto :cmd_start
if /i "%~1"=="stop"    goto :cmd_stop
if /i "%~1"=="restart" goto :cmd_restart
if /i "%~1"=="status"  goto :cmd_status
if /i "%~1"=="logs"    goto :cmd_logs
if /i "%~1"=="help"    goto :show_help
if "%~1"==""           goto :cmd_foreground
goto :show_help

:cmd_foreground
call :run_foreground
goto :end

:cmd_start
call :start_service
goto :end

:cmd_stop
call :stop_service
goto :end

:cmd_restart
call :stop_service
call :sleep1
call :start_service
goto :end

:cmd_status
call :show_status
goto :end

:cmd_logs
call :show_logs
goto :end


REM ================================================================
REM  Subroutines
REM ================================================================

REM -- find the PID listening on our port (empty if none) -----------
REM Why not the PID file: `start` gives no dependable PID, and once
REM the stored PID drifts from reality (different window, external
REM restart) stop either kills the wrong thing or nothing at all.
REM Looking the port up is always right.
:find_listen_pid
set "LISTEN_PID="
for /f "tokens=5" %%P in ('netstat -ano ^| findstr /c:":%PORT% " ^| findstr /c:"LISTENING"') do (
  if not defined LISTEN_PID set "LISTEN_PID=%%P"
)
goto :eof

REM -- is the service actually ready? -------------------------------
:is_ready
where curl >nul 2>&1
if errorlevel 1 (
  REM No curl (needs Win10 1803+). Degrade to "port is listening":
  REM not as precise as a health check, but better than stalling.
  call :find_listen_pid
  if defined LISTEN_PID (exit /b 0) else (exit /b 1)
)
curl -sf -m 2 "http://127.0.0.1:%PORT%/api/health" >nul 2>&1
exit /b %errorlevel%

REM -- sleep 1s (timeout breaks when stdin is redirected) -----------
:sleep1
ping -n 2 127.0.0.1 >nul 2>&1
goto :eof

REM -- start --------------------------------------------------------
:start_service
call :find_listen_pid
if defined LISTEN_PID (
  echo Already running on port %PORT% ^(PID !LISTEN_PID!^)
  goto :eof
)

REM Prefer the server's own virtualenv - dependencies live in
REM server\.venv, a bare `python` from PATH will fail to import.
call :locate_python
if not defined PY (
  echo [ERROR] Python not found. Create the server virtualenv first:
  echo         cd server
  echo         python -m venv .venv
  echo         .venv\Scripts\pip install -r requirements.txt
  exit /b 1
)

echo Starting ZeekrDash on http://%HOST%:%PORT%
echo   interpreter: %PY%

REM Deliberately NOT setting PYTHONIOENCODING. Left alone, Python writes
REM stdout with the locale codec (GBK on zh-CN), which is exactly what
REM this console speaks - so the log reads correctly with `type` and in
REM any GBK-aware editor. Forcing UTF-8 here was a mistake: it made the
REM log unreadable in CMD just to please editors that were never the
REM primary reader. scripts\logs_tail.py auto-detects either one anyway.

REM /min opens a separate minimized console. The service MUST break
REM away from the current console - otherwise closing the caller's
REM window takes the whole console process tree with it.
REM The banner matters: everything the service prints is redirected
REM into the log file, so without it this window looks empty and
REM people assume the service died.
start "ZeekrDash" /min /d "%SERVER_DIR%" cmd /c "echo ZeekrDash is running.  Log: server\.server.log    Follow it with: scripts\server.cmd logs & "%PY%" -m uvicorn app.main:app --host %HOST% --port %PORT% >> "%LOG_FILE%" 2>&1"

set /a WAITED=0
:start_wait
call :is_ready
if not errorlevel 1 goto :start_ok
ping -n 2 127.0.0.1 >nul 2>&1
set /a WAITED+=1
if !WAITED! lss 20 goto :start_wait

echo [FAILED] Timed out waiting for the service.
echo          Log: %LOG_FILE%
echo          Run "%~nx0 logs" to read it
exit /b 1

:start_ok
call :find_listen_pid
if defined LISTEN_PID (
  >"%PID_FILE%" echo !LISTEN_PID!
  echo [OK] Service ready ^(PID !LISTEN_PID!^)
) else (
  echo [OK] Service ready on port %PORT%
)
echo     preview: http://127.0.0.1:%PORT%/preview/index.html
echo     debug:   http://127.0.0.1:%PORT%/preview/debug.html
goto :eof

REM -- stop ---------------------------------------------------------
:stop_service
call :find_listen_pid
if not defined LISTEN_PID (
  echo Not running ^(nothing listening on port %PORT%^)
  if exist "%PID_FILE%" del "%PID_FILE%" >nul 2>&1
  goto :eof
)

echo Stopping PID !LISTEN_PID! on port %PORT%
taskkill /PID !LISTEN_PID! /F >nul 2>&1

REM Success is judged by "the port is really gone", never by
REM "we issued the kill" - the .sh version once reported success
REM while the service kept running.
set /a WAITED=0
:stop_wait
call :find_listen_pid
if not defined LISTEN_PID goto :stop_ok
ping -n 2 127.0.0.1 >nul 2>&1
set /a WAITED+=1
if !WAITED! lss 15 goto :stop_wait

echo [FAILED] Port %PORT% is still held by PID !LISTEN_PID!
exit /b 1

:stop_ok
if exist "%PID_FILE%" del "%PID_FILE%" >nul 2>&1
echo [OK] Stopped
goto :eof

REM -- status -------------------------------------------------------
:show_status
call :find_listen_pid
if not defined LISTEN_PID (
  echo [DOWN] nothing listening on port %PORT%
  goto :eof
)
echo [UP] port %PORT%, PID !LISTEN_PID!
call :is_ready
if errorlevel 1 (
  echo      health: no response yet ^(process exists, service not ready^)
) else (
  echo      health: OK
  where curl >nul 2>&1 && curl -s "http://127.0.0.1:%PORT%/api/health"
)
goto :eof

REM -- logs ---------------------------------------------------------
REM Live follow, like `tail -f`: print the tail of the file once, then
REM keep printing whatever gets appended. Ctrl+C to stop.
REM
REM Encoding note: the log is UTF-8 while this console is GBK, so
REM Chinese log text may look garbled here. ASCII parts (timestamps,
REM levels, HTTP status) stay readable - and those carry the
REM diagnostic signal. Open the file in a UTF-8 editor for the rest.
:show_logs
if not exist "%LOG_FILE%" (
  echo No log yet: %LOG_FILE%
  echo Start the service first.
  goto :eof
)

REM Reuse the same interpreter lookup as the start path.
set "PYLOG="
if exist "%SERVER_DIR%\.venv\Scripts\python.exe" set "PYLOG=%SERVER_DIR%\.venv\Scripts\python.exe"
if not defined PYLOG (
  where python >nul 2>&1 && set "PYLOG=python"
)

echo ---- %LOG_FILE% ----
echo ---- last 25 lines, then following live ^(Ctrl+C to stop^) ----
echo.

if defined PYLOG (
  REM logs_tail.py does two things batch cannot do reliably: print only
  REM the newly appended lines, and re-encode the UTF-8 log for a GBK
  REM console so Chinese text is actually readable.
  "%PYLOG%" "%SCRIPT_DIR%logs_tail.py" "%LOG_FILE%"
  goto :eof
)

REM Fallback without Python: dump what is there and say so.
echo ^(Python not found - showing a one-off dump instead of a live follow^)
type "%LOG_FILE%"
echo.
echo ---- end ^(re-run this command for the latest^) ----
goto :eof

REM -- run in the foreground (the default, i.e. double-click) ------
REM Logs go straight to this console: no redirection, no second
REM window, no log file to chase. Ctrl+C stops the service.
REM
REM PYTHONIOENCODING is deliberately NOT set here. Left alone, Python
REM writes stdout with the locale codec, which matches this console's
REM code page - that is exactly why the Chinese log lines come out
REM readable instead of as mojibake.
:run_foreground
call :find_listen_pid
if defined LISTEN_PID (
  echo Already running on port %PORT% ^(PID !LISTEN_PID!^)
  echo.
  echo   watch its log : %~nx0 logs
  echo   stop it       : %~nx0 stop
  echo   all commands  : %~nx0 help
  echo.
  pause
  goto :eof
)

call :locate_python
if not defined PY (
  echo [ERROR] Python not found. See: %~nx0 help
  echo.
  pause
  goto :eof
)

echo ZeekrDash - starting in this window.
echo Logs print below. Press Ctrl+C to stop.
echo Other commands: %~nx0 help
echo.

cd /d "%SERVER_DIR%"
"%PY%" -m uvicorn app.main:app --host %HOST% --port %PORT%

echo.
echo Service stopped.
pause
goto :eof

REM -- find an interpreter (server venv first) ----------------------
:locate_python
set "PY="
if exist "%SERVER_DIR%\.venv\Scripts\python.exe" set "PY=%SERVER_DIR%\.venv\Scripts\python.exe"
if not defined PY (
  where python >nul 2>&1 && set "PY=python"
)
goto :eof

REM -- help ---------------------------------------------------------
:show_help
echo ZeekrDash service manager
echo.
call :find_listen_pid
if defined LISTEN_PID (
  echo status: RUNNING on port %PORT%, PID !LISTEN_PID!
) else (
  echo status: NOT running
)
echo.
echo Usage: %~nx0 ^[command^]
echo.
echo   ^(no command^)  run the service HERE and print its log
echo                 - this is what double-clicking does
echo   start     run it detached ^(minimized window, log to server\.server.log^)
echo   stop      stop the service
echo   restart   stop, then start detached
echo   status    show status and health check
echo   logs      follow the log file live ^(for services started with "start"^)
echo.
echo Normally you just double-click this file.
echo.
pause

:end
endlocal
