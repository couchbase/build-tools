set INSTALL_DIR=%1
set ROOT_DIR=%2
set PROFILE=%4
set ARCH=%8

cd %ROOT_DIR%\openssl

rem Need to add ActivePerl to path
set PATH=C:\Perl64\bin;%PATH%

rem Build OpenSSL binary and libraries
if "%ARCH%" == "x86" (
    set CONFIG=VC-WIN32
) else (
    set CONFIG=VC-WIN64A
)
call perl Configure %CONFIG% --prefix=%CD%\build || goto error
call nmake || goto error
call nmake install || goto error
call xcopy /IE %CD%\build %INSTALL_DIR% || goto error
call rmdir /s /q %INSTALL_DIR%\html || goto error

set STATIC_DIR=%INSTALL_DIR%\lib\VC\static
if "%PROFILE%" == "server" (
    rem Erlang wants static openssl libs, and expects them to be named
    rem the way OpenSSL distributions do. Since nobody else cares, go
    rem along with that.
    call mkdir %STATIC_DIR% || goto error
    call copy libcrypto_static.lib %STATIC_DIR%\libcrypto64MD.lib || goto error
    call copy libssl_static.lib %STATIC_DIR%\libssl64MD.lib || goto error
    goto :eof
)

:error
echo Failed with error %ERRORLEVEL%
exit /B %ERRORLEVEL%
