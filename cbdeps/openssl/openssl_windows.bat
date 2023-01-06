set INSTALL_DIR=%1
set ROOT_DIR=%2
set PROFILE=%4
set VERSION=%5
set ARCH=%8

cd %ROOT_DIR%\openssl

rem Need to add ActivePerl to path
set PATH=C:\Perl64\bin;%PATH%

set DRIVE=c:
set SERVER_DIR=Program Files\Couchbase\Server
set PREFIX=%DRIVE%\%SERVER_DIR%
set OPENSSLDIR=%SERVER_DIR%

rem Build OpenSSL binary and libraries
if "%ARCH%" == "x86" (
    set CONFIG=VC-WIN32
) else (
    set CONFIG=VC-WIN64A
)


if EXIST VERSION.dat (
    rem OpenSSL 3.x
    set OPENSSLDIR=%SERVER_DIR%\etc\openssl
    if "%VERSION:~-4%" == "fips" (
        rem OpenSSL 3.x + FIPS
        set CONFIG=%CONFIG% enable-fips

        powershell -Command "(Get-Content apps/openssl.cnf) -replace """"# .include fipsmodule.cnf"""", """".include '%PREFIX:\=\\%\\fipsmodule.cnf'"""" | Out-File -encoding ASCII apps/openssl.cnf"
        powershell -Command "(Get-Content apps/openssl.cnf) -replace """"# fips = fips_sect"""", """"fips = fips_sect`r`nbase = base_sect`r`n`r`n[base_sect]`r`nactivate = 1`r`n"""" | Out-File -encoding ASCII apps/openssl.cnf"
        set OPENSSLDIR=%SERVER_DIR%\etc\openssl\fips
    )
)

call perl Configure %CONFIG% --prefix="%PREFIX%" --openssldir="%DRIVE%\%OPENSSLDIR%" || goto error

call nmake || goto error
call nmake install DESTDIR=%INSTALL_DIR% || goto error

call del /Q /F "%INSTALL_DIR%\%OPENSSLDIR%\*.dist" || goto error
rem call xcopy /IE %CD%\build %INSTALL_DIR% || goto error
call rmdir /s /q "%INSTALL_DIR%\%SERVER_DIR%\html" || goto error

set STATIC_DIR=%INSTALL_DIR%\%SERVER_DIR%\lib\VC\static
if "%PROFILE%" == "server" (
    rem Erlang wants static openssl libs, and expects them to be named
    rem the way OpenSSL distributions do. Since nobody else cares, go
    rem along with that.
    call mkdir "%STATIC_DIR%" || goto error
    call copy libcrypto_static.lib "%STATIC_DIR%\libcrypto64MD.lib" || goto error
    call copy libssl_static.lib "%STATIC_DIR%\libssl64MD.lib" || goto error
    goto :eof
)

:error
echo Failed with error %ERRORLEVEL%
exit /B %ERRORLEVEL%
