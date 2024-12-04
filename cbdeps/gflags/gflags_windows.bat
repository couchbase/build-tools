set INSTALL_DIR=%1
set ROOT_DIR=%2

cd %ROOT_DIR%

cmake -B build -S "%ROOT_DIR%/gflags" ^
    -G Ninja ^
    -D CMAKE_INSTALL_PREFIX=%INSTALL_DIR% ^
    -D CMAKE_BUILD_TYPE=RelWithDebInfo ^
    -D BUILD_SHARED_LIBS=OFF ^
    -D CMAKE_POSITION_INDEPENDENT_CODE=ON
cd build
ninja -j8 install

cd ..

@REM Additionally build a Debug variant on Windows, as for a debug build of
@REM CB Server we need all dependencies _also_ linked against Debug CRT.
cmake -B build-debug -S "%ROOT_DIR%/gflags" ^
    -G Ninja ^
    -D CMAKE_INSTALL_PREFIX=%INSTALL_DIR% ^
    -D CMAKE_BUILD_TYPE=Debug ^
    -D BUILD_SHARED_LIBS=OFF ^
    -D CMAKE_POSITION_INDEPENDENT_CODE=ON
cd build-debug
ninja -j8 install
