set INSTALL_DIR=%1
set ROOT_DIR=%2

set ZLIB_VER=1.2.13-1

set DEPSDIR=%WORKSPACE%\deps
rmdir /s /q %DEPSDIR%
mkdir %DEPSDIR%
cbdep install -d %DEPSDIR% zlib %ZLIB_VER%
set ZLIB_PATH=%DEPSDIR%\zlib-%ZLIB_VER%

cd %ROOT_DIR%\curl

set OUTPUT_DIR=builds\libcurl-vc17-x64-release-dll-zlib-dll-ipv6-sspi-schannel

call .\buildconf.bat || goto error
@echo on
cd winbuild
call nmake -f Makefile.vc ^
  mode=dll VC=17 MACHINE=x64 DEBUG=no GEN_PDB=yes ^
  WITH_ZLIB=dll ZLIB_PATH=%ZLIB_PATH% ^
  || goto error

cd ..
xcopy %OUTPUT_DIR% %INSTALL_DIR% /s || goto error

goto :eof

:error
echo Failed with error %ERRORLEVEL%
exit /B %ERRORLEVEL%
