@echo on

set INSTALL_DIR=%1
set ROOT_DIR=%2

cd %ROOT_DIR%\libsodium


pushd builds\msvc\build
rem buildbase.bat uses Enterprise or Community version of MSVS to do builds
rem We have Professional version.  Replace Community with Professional before running it.
setlocal enabledelayedexpansion
powershell -Command "(gc buildbase.bat) -replace 'Community','Professional' | Set-Content buildbase.bat"


rem Build libsodium libraries
call buildbase.bat ..\vs2017\libsodium.sln 15 || goto error

popd

rem Copy right stuff to output directory.
mkdir %INSTALL_DIR%\lib
mkdir %INSTALL_DIR%\include\sodium

copy bin\x64\Release\v141\dynamic\libsodium.lib %INSTALL_DIR%\lib || goto error
copy bin\x64\Release\v141\dynamic\libsodium.pdb %INSTALL_DIR%\lib || goto error
copy bin\x64\Release\v141\dynamic\libsodium.dll %INSTALL_DIR%\bin || goto error

copy src\libsodium\include\sodium.h %INSTALL_DIR%\include || goto error
copy src\libsodium\include\sodium\*.h %INSTALL_DIR%\include\sodium || goto error

goto :eof

:error
echo Failed with error %ERRORLEVEL%
exit /B %ERRORLEVEL%
