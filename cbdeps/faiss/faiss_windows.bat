
set INSTALL_DIR=%1
set ROOT_DIR=%2
set PROFILE=%4

cd %ROOT_DIR%

rem Just way easier to extract the OpenBLAS and LLVM versions from the manifest
rem using bash
set PATH=%PATH%;c:\cygwin\bin
for /F %%I in ('sh -c "./build-tools/utilities/annot_from_manifest OPENBLAS_VERSION"') do @set "OPENBLAS_VER=%%I" || goto :error
for /F %%I in ('sh -c "./build-tools/utilities/annot_from_manifest LLVM_OPENMP_VERSION"') do @set "LLVM_OPENMP_VER=%%I" || goto :error

rem Install openblas
cbdep -p windows install -d deps -C openblas %OPENBLAS_VER% || goto :error

rem Build OpenMP - see faiss_unix.sh for some details about this process
git clone --branch llvmorg-%LLVM_OPENMP_VER% ^
    -n --depth=1 --filter=tree:0 ^
    https://github.com/llvm/llvm-project openmp_src || goto :error
cd openmp_src
git sparse-checkout set cmake openmp || goto :error
git checkout || goto :error

cmake -B build -S %ROOT_DIR%\openmp_src\openmp -G Ninja ^
    -DCMAKE_BUILD_TYPE=Release ^
    -DCMAKE_C_COMPILER=clang-cl -DCMAKE_CXX_COMPILER=clang-cl ^
    -DCMAKE_INSTALL_PREFIX=%ROOT_DIR%\openmp_src\install || goto :error
cd build
ninja install || goto :error

rem We don't actually need this file for compiling, only at runtime.
rem And it has to have a special name.
cd ..\install\bin
mkdir %INSTALL_DIR%\bin || goto :error
copy libomp.dll %INSTALL_DIR%\bin\libomp140.x86_64.dll || goto :error

cd %ROOT_DIR%

cmake -B build -S %ROOT_DIR%\faiss -G Ninja ^
    -DCMAKE_BUILD_TYPE=RelWithDebInfo ^
    -DCMAKE_C_COMPILER=clang-cl -DCMAKE_CXX_COMPILER=clang-cl ^
    -DCMAKE_PREFIX_PATH=%ROOT_DIR%\deps\openblas-%OPENBLAS_VER% ^
    -DCMAKE_WINDOWS_EXPORT_ALL_SYMBOLS=ON ^
    -DFAISS_ENABLE_GPU=OFF -DFAISS_ENABLE_PYTHON=OFF -DFAISS_ENABLE_C_API=ON ^
    -DFAISS_OPT_LEVEL=%PROFILE% ^
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
