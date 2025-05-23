@echo on

set INSTALL_DIR=%1
set ROOT_DIR=%2

cd %ROOT_DIR%\simdutf

rmdir /s /q build
mkdir build
cd build
cmake -G Ninja ^
    -DCMAKE_BUILD_TYPE=RelWithDebInfo ^
    -DCMAKE_INSTALL_PREFIX=%INSTALL_DIR% ^
    -DCMAKE_INSTALL_LIBDIR=lib ^
    -DSIMDUTF_BENCHMARKS=OFF ^
    -DSIMDUTF_TESTS=OFF ^
    -DSIMDUTF_ICONV=OFF ^
    -DSIMDUTF_TOOLS=OFF ^
    .. || goto :error
ninja install ||s goto :error

rmdir /s /q %INSTALL_DIR%\lib\pkgconfig

goto :eof

:error
echo Failed with error %ERRORLEVEL%
exit /B %ERRORLEVEL%
