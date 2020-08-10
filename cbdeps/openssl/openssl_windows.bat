set INSTALL_DIR=%1
set ROOT_DIR=%2

cd %ROOT_DIR%\openssl

rem Need to add ActivePerl to path
set PATH=C:\Perl64\bin;%PATH%

rem Build OpenSSL binary and libraries
call perl Configure VC-WIN64A --prefix=%CD%\build || goto error
call nmake || goto error
call nmake install || goto error
call xcopy /IE %CD%\build %INSTALL_DIR% || goto error
call rmdir /s /q %INSTALL_DIR%\html || goto error
goto :eof

:error
echo Failed with error %ERRORLEVEL%
exit /B %ERRORLEVEL%
