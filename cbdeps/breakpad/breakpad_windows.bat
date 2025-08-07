set INSTALL_DIR=%1
set ROOT_DIR=%2

cd %ROOT_DIR%\breakpad

python3 -m venv ..\env
call ..\env\Scripts\activate
pip install six

set GYP_MSVS_VERSION=2022

rem Fix the build_all target to avoid GUID resolution issues
rem Apply fixes for Visual Studio 2022 compatibility
powershell -ExecutionPolicy Bypass -File "%~dp0\patches\0003-Fix-breakpad-gyp.ps1" || goto error

rem Apply patch to fix uninitialized variable warning that MSVC 2022 treats as error
powershell -ExecutionPolicy Bypass -File "%~dp0\patches\0004-Fix-uninitialized-variable-msvc2022.ps1" || goto error

rem win_{release,debug}_RuntimeLibrary: Breakpad defaults to building static
rem variants (/MT and /MTd) whereas we need the DLL variants.
rem Build each individual gyp file explicitly to ensure all libraries are built
call .\src\tools\gyp\gyp.bat .\src\client\windows\breakpad_client.gyp --no-circular-check -D win_release_RuntimeLibrary=2 -D win_debug_RuntimeLibrary=3 || goto error
call .\src\tools\gyp\gyp.bat .\src\client\windows\crash_generation\crash_generation.gyp --no-circular-check -D win_release_RuntimeLibrary=2 -D win_debug_RuntimeLibrary=3 || goto error
call .\src\tools\gyp\gyp.bat .\src\client\windows\handler\exception_handler.gyp --no-circular-check -D win_release_RuntimeLibrary=2 -D win_debug_RuntimeLibrary=3 || goto error
call .\src\tools\gyp\gyp.bat .\src\client\windows\sender\crash_report_sender.gyp --no-circular-check -D win_release_RuntimeLibrary=2 -D win_debug_RuntimeLibrary=3 || goto error
call .\src\tools\gyp\gyp.bat .\src\client\windows\unittests\testing.gyp --no-circular-check -D win_release_RuntimeLibrary=2 -D win_debug_RuntimeLibrary=3 || goto error
call .\src\tools\gyp\gyp.bat .\src\client\windows\unittests\client_tests.gyp --no-circular-check -D win_release_RuntimeLibrary=2 -D win_debug_RuntimeLibrary=3 || goto error

rem Build each solution file individually (skip the problematic breakpad_client.sln with build_all target)
rem Build common.vcxproj first as it's a dependency for others
call msbuild .\src\client\windows\common.vcxproj /p:Configuration="Release" /p:Platform="x64" || goto error
call msbuild .\src\client\windows\common.vcxproj /p:Configuration="Debug" /p:Platform="x64" || goto error

call msbuild .\src\client\windows\crash_generation\crash_generation.sln /p:Configuration="Release" /p:Platform="x64" || goto error
call msbuild .\src\client\windows\crash_generation\crash_generation.sln /p:Configuration="Debug" /p:Platform="x64" || goto error

call msbuild .\src\client\windows\handler\exception_handler.sln /p:Configuration="Release" /p:Platform="x64" || goto error
call msbuild .\src\client\windows\handler\exception_handler.sln /p:Configuration="Debug" /p:Platform="x64" || goto error

call msbuild .\src\client\windows\sender\crash_report_sender.sln /p:Configuration="Release" /p:Platform="x64" || goto error
call msbuild .\src\client\windows\sender\crash_report_sender.sln /p:Configuration="Debug" /p:Platform="x64" || goto error

rem Build individual testing vcxproj files to avoid GUID dependency issues
call msbuild .\src\client\windows\unittests\gtest.vcxproj /p:Configuration="Release" /p:Platform="x64" || goto error
call msbuild .\src\client\windows\unittests\gtest.vcxproj /p:Configuration="Debug" /p:Platform="x64" || goto error

call msbuild .\src\client\windows\unittests\gmock.vcxproj /p:Configuration="Release" /p:Platform="x64" || goto error
call msbuild .\src\client\windows\unittests\gmock.vcxproj /p:Configuration="Debug" /p:Platform="x64" || goto error

call msbuild .\src\client\windows\unittests\processor_bits.vcxproj /p:Configuration="Release" /p:Platform="x64" || goto error
call msbuild .\src\client\windows\unittests\processor_bits.vcxproj /p:Configuration="Debug" /p:Platform="x64" || goto error

rem Debug and Release libraries (each in their own subdir)
mkdir %INSTALL_DIR%\lib\Debug || goto error
copy .\src\client\windows\Debug\lib\common.lib %INSTALL_DIR%\lib\Debug || goto error
copy .\src\client\windows\crash_generation\Debug\lib\crash_generation_client.lib %INSTALL_DIR%\lib\Debug || goto error
copy .\src\client\windows\crash_generation\Debug\lib\crash_generation_server.lib %INSTALL_DIR%\lib\Debug || goto error
copy .\src\client\windows\handler\Debug\lib\exception_handler.lib %INSTALL_DIR%\lib\Debug || goto error
copy .\src\client\windows\sender\Debug\lib\crash_report_sender.lib %INSTALL_DIR%\lib\Debug || goto error
copy .\src\client\windows\unittests\Debug\lib\gtest.lib %INSTALL_DIR%\lib\Debug || goto error
copy .\src\client\windows\unittests\Debug\lib\gmock.lib %INSTALL_DIR%\lib\Debug || goto error
copy .\src\client\windows\unittests\Debug\lib\processor_bits.lib %INSTALL_DIR%\lib\Debug || goto error

mkdir %INSTALL_DIR%\lib\Release || goto error
copy .\src\client\windows\Release\lib\common.lib %INSTALL_DIR%\lib\Release || goto error
copy .\src\client\windows\crash_generation\Release\lib\crash_generation_client.lib %INSTALL_DIR%\lib\Release || goto error
copy .\src\client\windows\crash_generation\Release\lib\crash_generation_server.lib %INSTALL_DIR%\lib\Release || goto error
copy .\src\client\windows\handler\Release\lib\exception_handler.lib %INSTALL_DIR%\lib\Release || goto error
copy .\src\client\windows\sender\Release\lib\crash_report_sender.lib %INSTALL_DIR%\lib\Release || goto error
copy .\src\client\windows\unittests\Release\lib\gtest.lib %INSTALL_DIR%\lib\Release || goto error
copy .\src\client\windows\unittests\Release\lib\gmock.lib %INSTALL_DIR%\lib\Release || goto error
copy .\src\client\windows\unittests\Release\lib\processor_bits.lib %INSTALL_DIR%\lib\Release || goto error

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
