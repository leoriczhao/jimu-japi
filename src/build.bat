@echo off
rem Build yd_japi.dll / newD3d9.dll / d3d_sdk_contract_test.exe (Win32 Release).
rem Run from anywhere: every path below is derived from this file's own location.
setlocal

rem Default toolchain. Point this at your own vcvars32.bat, or delete it and the
rem vswhere lookup below finds the newest Visual Studio with the x86 C++ tools.
set "VCVARS=D:\vs2022\BuildTools\VC\Auxiliary\Build\vcvars32.bat"
if not exist "%VCVARS%" (
    for /f "usebackq delims=" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2^>nul`) do set "VCVARS=%%i\VC\Auxiliary\Build\vcvars32.bat"
)
if not exist "%VCVARS%" (
    echo [build] vcvars32.bat not found - install the Visual Studio C++ build tools,
    echo [build] or set VCVARS at the top of %~nx0.
    exit /b 2
)

call "%VCVARS%" > nul
cd /d "%~dp0"
if not exist build mkdir build
cd build
cmake .. -G "Visual Studio 17 2022" -A Win32
if %ERRORLEVEL% NEQ 0 exit /b %ERRORLEVEL%
cmake --build . --config Release
exit /b %ERRORLEVEL%
