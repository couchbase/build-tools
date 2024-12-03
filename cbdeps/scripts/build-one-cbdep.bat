setlocal EnableDelayedExpansion


rem Need to extract final part of PRODUCT to get actual product name
powershell -command "& { ('%PRODUCT%' -split '::')[-1] }" > temp.txt
set /p PROD_NAME=<temp.txt
powershell -command "& { '%PRODUCT%' -replace '::','/' }" > temp2.txt
set /p PROD_PATH=<temp2.txt

if "%WORKSPACE%" == "" (
  set ROOT_DIR=%CD%
) else (
  set ROOT_DIR=%WORKSPACE%
)
cd %ROOT_DIR%

rem Ensure latest cbdep tool is on PATH
if not exist tools (
  mkdir tools
)

set CBDEP_FILENAME=%ROOT_DIR%\tools\cbdep.exe
set CBDEP_URL=https://packages.couchbase.com/cbdep/cbdep-windows.exe
set SECURITYPROTOCOL=[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
if not exist %CBDEP_FILENAME% (
  powershell -command "& { %SECURITYPROTOCOL%; Invoke-WebRequest -Uri %CBDEP_URL% -Outfile %CBDEP_FILENAME% }" || goto error
)
set PATH=%ROOT_DIR%\tools;%PATH%

if NOT "%PROFILE%" == "server" (
  set BLD_NUM=%BLD_NUM%_%PROFILE%
)

rem Our Jenkins labels and Jenkins job ARCH parameters are standardized
rem on x86_64, but that's not what this script wants
if "%ARCH%" == "x86_64" (
  set ARCH=amd64
)

if not defined ARCH (
  set ARCH=amd64
)

echo "Performing build..."
set "SCRIPT_DIR=%~dp0"
call :normalizepath "!SCRIPT_DIR!..\%PROD_NAME%"
set "PACKAGE_DIR=!RETVAL!"

set INSTALL_DIR=%ROOT_DIR%\install
rmdir /s /q %INSTALL_DIR%
mkdir %INSTALL_DIR% || goto error

rem Create META directory for cbdeps-specific metadata
mkdir %INSTALL_DIR%\META

rem When compiling V8, Gyp expects the TMP variable to be set
set TMP=C:\Windows\Temp
rem Default value for source_root (ignored but must be set)
set source_root=%CD%

:do_build
set target_arch=%ARCH%
call %SCRIPT_DIR%\win32-environment.bat %PLATFORM% || goto error
@echo on
cd %PACKAGE_DIR% || goto error
call %PROD_NAME%_windows.bat %INSTALL_DIR% %ROOT_DIR% %PLATFORM% %PROFILE% %RELEASE% %VERSION% %BLD_NUM% %ARCH% || goto error
cd %PACKAGE_DIR% || goto error
@echo on

echo "Preparing for package..."
if exist "package" (
  xcopy package\* %INSTALL_DIR% /s /e /y || goto error
)
echo %VERSION%-%BLD_NUM% > %INSTALL_DIR%\VERSION.txt

echo "Create package..."
set PKG_DIR=%ROOT_DIR%\packages\%PROD_NAME%\%VERSION%\%BLD_NUM%
rmdir /s /q %PKG_DIR%
mkdir %PKG_DIR% || goto error
cd %INSTALL_DIR% || goto error

rem We're going to make all Windows packages have the platform "windows" now
set TARBALL_NAME=%PROD_NAME%-windows-%ARCH%-%VERSION%-%BLD_NUM%.tgz
set MD5_NAME=%PROD_NAME%-windows-%ARCH%-%VERSION%-%BLD_NUM%.md5

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
