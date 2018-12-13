@echo on

rem Full PHP version, eg. 7.1.22
set PHPVER=%1
rem zts or nts
set TS=%2
rem with igbinary = 1, without = 0
set IGBINARY=%3
rem Path to work in (will just create "php-sdk" dir here)
set WORKDIR=%4
rem Path to produce output in (will create full tagged directories)
set INSTALLDIR=%5

set STARTDIR=%CD%

if "%TS%" == "zts" (
  set tsarg=
) else (
  set tsarg=--disable-zts
)

if %IGBINARY% == 1 (
  set igtag=igbinary
  set igarg=--enable-igbinary=shared
) else (
  set igtag=default
  set igarg=
)

set PHPTAG=php-%PHPVER%-%TS%-%PHP_SDK_VC%-%PHP_SDK_OS_ARCH%-%igtag%
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
  bin\curl --insecure https://phar.phpunit.de/phpunit-5.7.phar -o php-phpunit.phar
)
if not exist php-phpdoc.phar (
  bin\curl --insecure https://phpdoc.org/phpDocumentor.phar -o php-phpdoc.phar
)
popd

rem Get igbinary if necessary
set igpath=..\deps\igbinary-2.0.1.tgz
if %IGBINARY% == 1 (
  if not exist "%igpath%" (
    ..\deps\bin\curl --insecure https://pecl.php.net/get/igbinary-2.0.1.tgz -o %igpath% || goto :error
  )
  7z x -tgzip -so ..\deps\igbinary-2.0.1.tgz | 7z x -y -ttar -si -oext\ || goto :error
  move /y ext\igbinary-2.0.1 ext\igbinary || goto :error
)

rem Configure and build
call buildconf || goto :error
@echo on
call configure --disable-all ^
  --enable-session --enable-json --enable-cli ^
  --enable-phar=shared ^
  %igarg% %tsarg% ^
  --with-prefix=%INSTALLDIR%\%PHPTAG% || goto :error
@echo on
nmake && nmake install || goto :error

rem Copy our extra dependencies
copy ..\deps\php-phpunit.phar %INSTALLDIR%\%PHPTAG%
copy ..\deps\php-phpdoc.phar %INSTALLDIR%\%PHPTAG%

:eof
exit /b 0

:error
set CODE=%ERRORLEVEL%
cd %STARTDIR%
echo Failed with code %CODE%.
exit /b %CODE%
