@echo on

set SCRIPTDIR=%~dp0
set CURDIR=%CD%

set INSTALL_DIR=%1
set PHPVER=%2
set BLD_NUM=%3

rem Check out the PHP Windows SDK from our fork
rem php-sdk-2.2.0 was the newest tag as of Jan. 14 2020
git clone git://github.com/couchbasedeps/php-sdk-binary-tools -b php-sdk-2.2.0 || goto :error

mkdir work

rem Choose correct VC
if "%PHPVER:~0,3%"=="7.3" (
    set VC=vc15
) else if "%PHPVER:~0,3%"=="7.4" (
    set VC=vc15
) else if "%PHPVER:~0,3%"=="8.0" (
    set VC=vs16
) else if "%PHPVER:~0,3%"=="8.1" (
    set VC=vs16
) else (
    echo Unsupported PHP version
    set ERRORLEVEL=1
    goto :error
)

echo @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
echo Building PHP %PHPVER% zts
echo @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@echo on
call %CURDIR%\php-sdk-binary-tools\phpsdk-starter.bat -c %VC% -a x64 ^
  -t %SCRIPTDIR%\windows_php_build_variant.bat ^
  --task-args "%PHPVER% %BLD_NUM% zts %CURDIR%\work %INSTALL_DIR%" || goto :error

echo @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
echo Building PHP %PHPVER% zts
echo @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@echo on
call %CURDIR%\php-sdk-binary-tools\phpsdk-starter.bat -c %VC% -a x64 ^
  -t %SCRIPTDIR%\windows_php_build_variant.bat ^
  --task-args "%PHPVER% %BLD_NUM% nts %CURDIR%\work %INSTALL_DIR%" || goto :error

move %INSTALL_DIR%\*.tgz %CURDIR%

:eof
exit /b 0

:error
set CODE=%ERRORLEVEL%
cd %STARTDIR%
echo Failed with code %CODE%.
exit /b %CODE%
