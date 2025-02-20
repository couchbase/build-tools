set INSTALL_DIR=%1
set ROOT_DIR=%2

set ZLIB_VER=1.2.13-2

set DEPSDIR=%WORKSPACE%\deps
rmdir /s /q %DEPSDIR%
mkdir %DEPSDIR%
cbdep -p windows install -d %DEPSDIR% zlib %ZLIB_VER% || goto error
set ZLIB_PATH=%DEPSDIR%\zlib-%ZLIB_VER%

cd %ROOT_DIR%\curl

@echo on
mkdir build
cd build
cmake -G Ninja ^
  -DCMAKE_BUILD_TYPE=RelWithDebInfo ^
  -DBUILD_SHARED_LIBS=ON ^
  -D CURL_ZLIB=ON -D ZLIB_ROOT=%ZLIB_PATH% ^
  -D CURL_USE_LIBPSL=OFF ^
  -DCMAKE_INSTALL_PREFIX=%INSTALL_DIR% .. || goto error
ninja install || goto error

cd %ROOT_DIR%
xcopy %OUTPUT_DIR% %INSTALL_DIR% /s || goto error

cd %INSTALL_DIR%
rmdir /s /q share
cd bin
del curl-config mk*.*
cd ..\lib
rmdir /s /q pkgconfig

goto :eof

:error
echo Failed with error %ERRORLEVEL%
exit /B %ERRORLEVEL%
