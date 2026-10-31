@echo off
cd /d "%~dp0"
py -3.12 -m venv .venv
if errorlevel 1 goto fail
".venv\Scripts\python.exe" -m pip install -r requirements.txt
if errorlevel 1 goto fail
echo Setup complete. Double click start.cmd to open the application.
pause
exit /b 0
:fail
echo Setup failed. Install Python 3.12 with Tcl/Tk and the Python launcher, then try again.
pause
exit /b 1
