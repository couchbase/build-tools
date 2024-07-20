set INSTALL_DIR=%1
set ROOT_DIR=%2

cd %ROOT_DIR%
mkdir lz4build
cd lz4build

cmake ^
    -G Ninja ^
    -DCMAKE_BUILD_TYPE=Release ^
    -DCMAKE_INSTALL_PREFIX=%INSTALL_DIR% ^
    -DCMAKE_MACOSX_RPATH=1 ^
    -DCMAKE_INSTALL_LIBDIR=lib ^
    %ROOT_DIR%/lz4/build/cmake
cmake --build . --target install

cd %INSTALL_DIR%\lib
rmdir /s /q pkgconfig
cd ..
rmdir /s /q share
cd bin
del *.exe
