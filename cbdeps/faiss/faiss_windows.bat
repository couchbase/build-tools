set INSTALL_DIR=%1
set ROOT_DIR=%2

cd %ROOT_DIR%

rem Just way easier to extract the OpenBLAS version from the manifest
rem using bash
set PATH=%PATH%;c:\cygwin\bin
for /F %%I in ('sh -c "./build-tools/utilities/annot_from_manifest OPENBLAS_VERSION"') do @set "OPENBLAS_VER=%%I" || goto :error
cbdep -p windows install -d deps -C openblas %OPENBLAS_VER% || goto :error

cd faiss
cmake -B build -G Ninja ^
    -DCMAKE_BUILD_TYPE=RelWithDebInfo ^
    -DCMAKE_PREFIX_PATH=%ROOT_DIR%\deps\openblas-%OPENBLAS_VER% ^
    -DCMAKE_WINDOWS_EXPORT_ALL_SYMBOLS=ON ^
    -DFAISS_ENABLE_GPU=OFF -DFAISS_ENABLE_PYTHON=OFF -DFAISS_ENABLE_C_API=ON ^
    -DCMAKE_INSTALL_PREFIX=%INSTALL_DIR% -DCMAKE_INSTALL_LIBDIR=lib ^
    -DBUILD_TESTING=OFF -DBUILD_SHARED_LIBS=ON || goto :error
cd build
ninja install || goto :error

goto :eof

:error
echo Failed with error %ERRORLEVEL%
exit /b %ERRORLEVEL%

:eof
exit /b 0
