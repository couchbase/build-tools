@echo on

set INSTALL_DIR=%1
set ROOT_DIR=%2

cd %ROOT_DIR%\zstd-cpp

rem Build zstd
set BUILD_DIR=build\cmake\build
mkdir %BUILD_DIR%
cd %BUILD_DIR%
cmake -DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl -G Ninja .. || goto :error
cmake --build . || goto :error
cmake --install . --prefix %INSTALL_DIR% || goto :error

del %INSTALL_DIR%\bin\zstd.exe || goto :error
rmdir /s /x %INSTALL_DIR%\lib\cmake

goto :eof

:error
echo Failed with error %ERRORLEVEL%
exit /B %ERRORLEVEL%
