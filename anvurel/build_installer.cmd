@echo off
setlocal
cd /d "%~dp0"

py -3.12 -c "import sys; assert sys.version_info[:2] == (3, 12)"
if errorlevel 1 goto missing_python

py -3.12 -m pip install -r requirements.txt -r requirements-transcription.txt pyinstaller
if errorlevel 1 goto failed

py -3.12 -m unittest discover -s . -p "test_*.py" -v
if errorlevel 1 goto failed

py -3.12 -m PyInstaller --clean --noconfirm anvurel.spec
if errorlevel 1 goto failed

set "ISCC="
if exist "%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe" set "ISCC=%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe"
if exist "%ProgramFiles%\Inno Setup 6\ISCC.exe" set "ISCC=%ProgramFiles%\Inno Setup 6\ISCC.exe"
if not defined ISCC goto missing_inno

if not exist installer\output mkdir installer\output
"%ISCC%" installer\ANVUREL.iss
if errorlevel 1 goto failed
echo Installer created at installer\output\ANVUREL-Setup-2.4.0.exe
pause
exit /b 0

:missing_python
echo Python 3.12 and the Python launcher are required to build the installer.
goto failed
:missing_inno
echo Install Inno Setup 6 to compile the Windows installer.
goto failed
:failed
echo Installer build did not complete.
pause
exit /b 1
