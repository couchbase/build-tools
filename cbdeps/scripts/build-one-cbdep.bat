setlocal EnableDelayedExpansion

rem Need to extract final part of PRODUCT to get actual product name
powershell -command "& { ('%PRODUCT%' -split '::')[-1] }" > temp.txt
set /p PROD_NAME=<temp.txt
powershell -command "& { '%PRODUCT%' -replace '::','/' }" > temp2.txt
set /p PROD_PATH=<temp2.txt
cd %WORKSPACE%

echo "Downloading source..."
set FILENAME=%PROD_NAME%-%VERSION%-%BLD_NUM%-source.tar.gz
set SITE=http://latestbuilds.service.couchbase.com/builds/latestbuilds/%PROD_PATH%/%VERSION%/%BLD_NUM%/%FILENAME%
powershell -command "& { (New-Object Net.WebClient).DownloadFile('%SITE%', '%FILENAME%') }" || goto error

echo "Extracting source..."
cmake -E tar xzf %FILENAME% || goto error

echo "Determine package name information..."
set ARCH=amd64
set TARBALL_NAME=%PROD_NAME%-%DISTRO%-%ARCH%-%VERSION%-%BLD_NUM%.tgz
set MD5_NAME=%PROD_NAME%-%DISTRO%-%ARCH%-%VERSION%-%BLD_NUM%.md5

echo "Performing build..."
set "SCRIPT_DIR=%~dp0"
call :normalizepath "!SCRIPT_DIR!.."
set "BASE_DIR=!RETVAL!"
set INSTALL_DIR=%BASE_DIR%\build\%PROD_NAME%\install

mkdir %INSTALL_DIR% || goto error

rem When compiling V8, Gyp expects the TMP variable to be set
set TMP=C:\Windows\Temp
rem Default value for source_root (ignored but must be set)
set source_root=%CD%

if "%DISTRO%" == "windows_msvc2017" (
  set tools_version=15.0
  goto do_build
)
if "%DISTRO%" == "windows_msvc2015" (
  set tools_version=14.0
  goto do_build
)
if "%DISTRO%" == "windows_msvc2013" (
  set tools_version=12.0
  goto do_build
)
rem Without year, VS version defaults to 2013
if "%DISTRO%" == "windows_msvc" (
  set tools_version=12.0
  goto do_build
)
if "%DISTRO%" == "windows_msvc2012" (
  set tools_version=11.0
  goto do_build
)

:do_build
set target_arch=%ARCH%
call %BASE_DIR%\win32\environment.bat %tools_version% || goto error
@echo on
cd %PROD_NAME% || goto error
call %BASE_DIR%\%PROD_NAME%\%PROD_NAME%_windows.bat %INSTALL_DIR% || goto error

echo "Preparing for packages..."
cd %WORKSPACE% || goto error
xcopy %BASE_DIR%\%PROD_NAME%\package\* %INSTALL_DIR% /s /e /y || goto error

echo "Create package..."
set PKG_DIR=%WORKSPACE%\packages\%PROD_NAME%\%VERSION%\%BLD_NUM%
mkdir %PKG_DIR% || goto error
cd %INSTALL_DIR% || goto error
cmake -E tar czf %PKG_DIR%\%TARBALL_NAME% . || goto error
cmake -E md5sum %PKG_DIR%\%TARBALL_NAME% > %PKG_DIR%\%MD5_NAME% || goto error

goto eof

:normalizepath
set "RETVAL=%~f1"
exit /b

:error
echo Failed with error %ERRORLEVEL%.
exit /b %ERRORLEVEL%

:eof
exit /b 0
