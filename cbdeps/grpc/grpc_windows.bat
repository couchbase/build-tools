set INSTALL_DIR=%1
set ROOT_DIR=%2
set PROFILE=%4

rem Download the right OpenSSL package depending on profile
if %PROFILE% == "server" (
  set OPENSSL_VER=1.1.1d-cb2
) else (
  set OPENSSL_VER=1.1.1g-sdk1
)

set CBDEPS_DIR=%CD%\cbdeps
mkdir %CBDEPS_DIR%
cd %CBDEPS_DIR%
curl -L https://packages.couchbase.com/cbdep/0.9.16/cbdep-0.9.16-windows.exe -o cbdep.exe || goto error
cbdep.exe install -d %CBDEPS_DIR% openssl %OPENSSL_VER% || goto error

cd %ROOT_DIR%\grpc
git submodule update --init --recursive || goto error

rem Build grpc binaries and libraries
rem Protobuf_USE_STATIC_LIBS necessary due to bug in CMake:
rem https://gitlab.kitware.com/paraview/paraview/issues/19527
mkdir .build
cd .build
cmake -G Ninja ^
  -D CMAKE_C_COMPILER=cl -D CMAKE_CXX_COMPILER=cl ^
  -D CMAKE_BUILD_TYPE=RelWithDebInfo ^
  -D "CMAKE_INSTALL_PREFIX=%INSTALL_DIR%" ^
  -D "CMAKE_PREFIX_PATH=%CBDEPS_DIR%\openssl-%OPENSSL_VER%" ^
  -DgRPC_INSTALL=ON ^
  -DgRPC_BUILD_TESTS=OFF ^
  -DgRPC_SSL_PROVIDER=package ^
  -DgRPC_BUILD_GRPC_RUBY_PLUGIN=OFF ^
  -DgRPC_BUILD_GRPC_PHP_PLUGIN=OFF ^
  -DgRPC_BUILD_GRPC_OBJECTIVE_C_PLUGIN=OFF ^
  -DgRPC_BUILD_GRPC_CSHARP_PLUGIN=OFF ^
  -DgRPC_BUILD_GRPC_NODE_PLUGIN=OFF ^
  -DProtobuf_USE_STATIC_LIBS=ON ^
  .. || goto error
ninja install || goto error

goto :eof

:error
echo Failed with error %ERRORLEVEL%
exit /B %ERRORLEVEL%
