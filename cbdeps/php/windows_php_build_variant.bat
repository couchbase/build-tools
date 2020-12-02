@echo on

rem Full PHP version, eg. 7.1.22
set PHPVER=%1
rem cb-specific rebuild number
set BLD_NUM=%2
rem zts or nts
set TS=%3
rem Path to work in (will just create "php-sdk" dir here)
set WORKDIR=%4
rem Path to produce output in (will create full tagged directories)
set INSTALLDIR=%5

set PHPUNIT_VER=9.4.3
set STARTDIR=%CD%

if "%TS%" == "zts" (
  set tsarg=
) else (
  set tsarg=--disable-zts
)

set PHPTAG=php-%TS%-default-%PHPVER%-cb%BLD_NUM%
rmdir /s /q %WORKDIR%\%PHPTAG%

rem Create working directory
mkdir %WORKDIR%\php-sdk
cd %WORKDIR%\php-sdk
call phpsdk_buildtree phpdev || goto :error

@echo on
rem Clone PHP source
if not exist "php-src.git" (
  git clone --bare git://github.com/php/php-src || goto :error
)
rmdir /s /q %PHPTAG%
git clone php-src -b php-%PHPVER% %PHPTAG% || goto :error
cd %PHPTAG%

rem Get PHP build dependencies
call phpsdk_deps -u || goto :error

@echo on
rem Get our extra dependencies
pushd ..\deps
if not exist php-phpunit.phar (
  curl --insecure -L https://phar.phpunit.de/phpunit-%PHPUNIT_VER%.phar -o php-phpunit.phar
)
if not exist php-phpdoc.phar (
  curl --insecure -L https://phpdoc.org/phpDocumentor.phar -o php-phpdoc.phar
)
popd

rem Compute whether we can safely enable json (< 8.0)
echo %PHPVER% | findstr /r /c:"^7\.[34]\."
if errorlevel 1 (
    set enablejson=--enable-json
) else (
    set enablejson=
)

rem Configure and build
call buildconf || goto :error
@echo on
call configure --disable-all --enable-sockets --enable-pcntl ^
  --enable-session %enablejson% --enable-cli ^
  --enable-phar=shared ^
  %tsarg% ^
  --with-prefix=%INSTALLDIR%\%PHPTAG% || goto :error
@echo on
nmake && nmake install || goto :error

rem Copy our extra dependencies
copy ..\deps\php-phpunit.phar %INSTALLDIR%\%PHPTAG%
copy ..\deps\php-phpdoc.phar %INSTALLDIR%\%PHPTAG%
xcopy /c /q /y /s /i %CURDIR%\php-sdk-binary-tools\msys2 %INSTALLDIR%\%PHPTAG%\msys2

rem Packaging
pushd %INSTALL_DIR%
cmake -E tar czf php-%TS%-default-windows-amd64-%PHPVER%-cb%BLD_NUM%.tgz %PHPTAG% || goto :error
popd

:eof
exit /b 0

:error
set CODE=%ERRORLEVEL%
cd %STARTDIR%
echo Failed with code %CODE%.
exit /b %CODE%
