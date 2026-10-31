@echo off
cd /d "%~dp0"
if not exist ".venv\Scripts\python.exe" (
  echo Run setup.cmd before installing the optional speech component.
  pause
  exit /b 1
)
".venv\Scripts\python.exe" -m pip install -r requirements-transcription.txt
if errorlevel 1 (
  echo Speech component setup failed. Check the internet connection and try again.
  pause
  exit /b 1
)
echo Speech component installed. Model downloads are controlled in ANVUREL.
pause
