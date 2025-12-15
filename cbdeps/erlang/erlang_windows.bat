@echo on

set INSTALL_DIR=%1
set ROOT_DIR=%2

cd %ROOT_DIR%

rem WSL handles all the heavy lifting now. Easiest to call this script in
rem the working directory to avoid backslashitis.
cd build-tools\cbdeps\erlang
"C:\Program Files\WSL\wsl.exe" bash -ex erlang_wsl_script.sh '%INSTALL_DIR%'

:error
echo Failed with error %ERRORLEVEL%
exit /B %ERRORLEVEL%
