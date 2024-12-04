set INSTALL_DIR=%1
set ROOT_DIR=%2

cd %ROOT_DIR%

cmake -B build -S "%ROOT_DIR%/fast_float" ^
    -G Ninja ^
    -D CMAKE_INSTALL_PREFIX=%INSTALL_DIR% ^
    -D CMAKE_BUILD_TYPE=RelWithDebInfo ^
    -D BUILD_SHARED_LIBS=OFF ^
    -D FASTFLOAT_CXX_STANDARD=17 ^
    -D CMAKE_POSITION_INDEPENDENT_CODE=ON

cd build

ninja -j8 install
