@echo on

set SCRIPTDIR=%~dp0
set CURDIR=%CD%

set INSTALL_DIR=%1
set PHPVER=%2
set BLD_NUM=%3

rem Check out the PHP Windows SDK from our fork
rem php-sdk-2.1.9 was the newest tag as of Dec. 13 2018
git clone git://github.com/couchbasedeps/php-sdk-binary-tools -b php-sdk-2.1.10 || goto :error

mkdir work

rem Choose correct VC
echo %PHPVER% | findstr /r /c:"^7\.[01]\."
if errorlevel 1 (
    set VC=vc15
) else (
    set VC=vc14
)

rem Build all versions
echo @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
echo Building PHP %PHPVER% zts with igbinary
echo @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@echo on
call %CURDIR%\php-sdk-binary-tools\phpsdk-starter.bat -c %VC% -a x64 ^
  -t %SCRIPTDIR%\windows_php_build_variant.bat ^
  --task-args "%PHPVER% %BLD_NUM% zts 1 %CURDIR%\work %INSTALL_DIR%" || goto :error

echo @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
echo Building PHP %PHPVER% zts without igbinary
echo @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@echo on
call %CURDIR%\php-sdk-binary-tools\phpsdk-starter.bat -c %VC% -a x64 ^
  -t %SCRIPTDIR%\windows_php_build_variant.bat ^
  --task-args "%PHPVER% %BLD_NUM% zts 0 %CURDIR%\work %INSTALL_DIR%" || goto :error

echo @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
echo Building PHP %PHPVER% nts with igbinary
echo @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@echo on
call %CURDIR%\php-sdk-binary-tools\phpsdk-starter.bat -c %VC% -a x64 ^
  -t %SCRIPTDIR%\windows_php_build_variant.bat ^
  --task-args "%PHPVER% %BLD_NUM% nts 1 %CURDIR%\work %INSTALL_DIR%" || goto :error

echo @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
echo Building PHP %PHPVER% zts without igbinary
echo @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@echo on
call %CURDIR%\php-sdk-binary-tools\phpsdk-starter.bat -c %VC% -a x64 ^
  -t %SCRIPTDIR%\windows_php_build_variant.bat ^
  --task-args "%PHPVER% %BLD_NUM% nts 0 %CURDIR%\work %INSTALL_DIR%" || goto :error

move %INSTALL_DIR%\*.tgz %CURDIR%

:eof
exit /b 0

:error
set CODE=%ERRORLEVEL%
cd %STARTDIR%
echo Failed with code %CODE%.
exit /b %CODE%
