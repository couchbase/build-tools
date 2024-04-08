set PLATFORM=%1

if "%PLATFORM%" == "windows_msvc2022" (
  set tools_version=2022
  goto do_tools_version
)
if "%PLATFORM%" == "windows_msvc2019" (
  set tools_version=2019
  goto do_tools_version
)
if "%PLATFORM%" == "windows_msvc2017" (
  set tools_version=2017
  goto do_tools_version
)
if "%PLATFORM%" == "windows_msvc2015" (
  set tools_version=14.0
  goto do_tools_version
)
if "%PLATFORM%" == "windows_msvc2013" (
  set tools_version=12.0
  goto do_tools_version
)
rem Without year, VS version defaults to 2013
if "%PLATFORM%" == "windows_msvc" (
  set tools_version=12.0
  goto do_tools_version
)
if "%PLATFORM%" == "windows_msvc2012" (
  set tools_version=11.0
  goto do_tools_version
)
echo "Unknown platform %PLATFORM%!"
exit /b 3

:do_tools_version
echo %tools_version%| FIND /I "201">Nul && (
  set "tools_dir=C:\Program Files (x86)\Microsoft Visual Studio\%tools_version%\Professional\VC\Auxiliary\Build"
) || echo %tools_version%| FIND /I "2022">Nul && (
  set "tools_dir=C:\Program Files\Microsoft Visual Studio\%tools_version%\Professional\VC\Auxiliary\Build"
) || (
  set "tools_dir=C:\Program Files (x86)\Microsoft Visual Studio %tools_version%\VC"
)
if not exist "%tools_dir%" (
  echo "%tools_dir% does not exist!"
  exit /b 5
)
echo Using tools from %tools_dir%

if not defined source_root (
  set source_root=%CD%
  echo source_root not set. It was automatically set to the current directory %CD%.
)

if not defined target_arch (
  set target_arch=amd64
  echo target_arch not set. It was automatically set to amd64.
)

if /i "%target_arch%" == "amd64" goto setup_amd64
if /i "%target_arch%" == "x86" goto setup_x86
if /i "%target_arch%" == "arm64" goto setup_arm64
goto missing_target_arch

:setup_x86
echo Setting up Visual Studio environment for x86
call "%tools_dir%\vcvarsall.bat" x86
goto eof

:setup_amd64
echo Setting up Visual Studio environment for amd64
call "%tools_dir%\vcvarsall.bat" amd64
goto eof

:setup_arm64
echo Setting up Visual Studio environment for cross amd64 -> arm64
call "%tools_dir%\vcvarsall.bat" x64_arm64
goto eof

:missing_root
echo source_root should be set in the source root
exit /b 1

:missing_target_arch
echo target_arch must be set in environment to x86 or amd64
exit /b 2

:eof
