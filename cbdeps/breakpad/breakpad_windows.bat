set INSTALL_DIR=%1
set ROOT_DIR=%2

cd %ROOT_DIR%\breakpad

set GYP_MSVS_VERSION=2015

rem win_{release,debug}_RuntimeLibrary: Breakpad defaults to building static
rem variants (/MT and /MTd) whereas we need the DLL variants.
call .\src\tools\gyp\gyp.bat .\src\client\windows\breakpad_client.gyp --no-circular-check -D win_release_RuntimeLibrary=2 -D win_debug_RuntimeLibrary=3 || goto error

call msbuild .\src\client\windows\breakpad_client.sln /p:Configuration="Release" /p:Platform="x64" || goto error
call msbuild .\src\client\windows\breakpad_client.sln /p:Configuration="Debug" /p:Platform="x64" || goto error

rem Debug and Release libraries (each in their own subdir)
mkdir %INSTALL_DIR%\lib\Debug || goto error
copy .\src\client\windows\Debug\lib\*.lib %INSTALL_DIR%\lib\Debug || goto error

mkdir %INSTALL_DIR%\lib\Release || goto error
copy .\src\client\windows\Release\lib\*.lib %INSTALL_DIR%\lib\Release || goto error

rem Header files
mkdir %INSTALL_DIR%\include\breakpad\client\windows\common || goto error
copy .\src\client\windows\common\ipc_protocol.h %INSTALL_DIR%\include\breakpad\client\windows\common || goto error

mkdir %INSTALL_DIR%\include\breakpad\client\windows\crash_generation || goto error
copy .\src\client\windows\crash_generation\crash_generation_client.h %INSTALL_DIR%\include\breakpad\client\windows\crash_generation || goto error

mkdir %INSTALL_DIR%\include\breakpad\client\windows\handler || goto error
copy .\src\client\windows\handler\exception_handler.h %INSTALL_DIR%\include\breakpad\client\windows\handler || goto error

mkdir %INSTALL_DIR%\include\breakpad\common || goto error
copy .\src\common\scoped_ptr.h %INSTALL_DIR%\include\breakpad\common || goto error

mkdir %INSTALL_DIR%\include\breakpad\common\windows || goto error
copy .\src\common\windows\string_utils-inl.h %INSTALL_DIR%\include\breakpad\common\windows || goto error

mkdir %INSTALL_DIR%\include\breakpad\google_breakpad\common || goto error
xcopy .\src\google_breakpad\common\* %INSTALL_DIR%\include\breakpad\google_breakpad\common /s /e /y || goto error

goto :eof

:error
echo Failed with error %ERRORLEVEL%
exit /b %ERRORLEVEL%

:eof
exit /b 0
