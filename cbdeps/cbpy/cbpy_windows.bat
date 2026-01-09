@echo on

set INSTALL_DIR=%1
set ROOT_DIR=%2
set VERSION=%6

rem cbpy version == included python version
set PYTHON_VERSION=%VERSION%
set UV_VERSION=0.9.23
set SRC_DIR=%ROOT_DIR%\build-tools\cbdeps\cbpy

rem Install UV
cbdep install -d C:\cb\deps uv %UV_VERSION% || goto error
set PATH=C:\cb\deps\uv-%UV_VERSION%\bin;%PATH%

rem Ask UV to install python
uv python install %PYTHON_VERSION%

rem Copy that python installation to INSTALL_DIR, and remove the magic
rem file that prevents 'uv pip' from manipulating it
for /F %%I in ('uv python find %PYTHON_VERSION%') do @set "PYTHON_EXE=%%I"
xcopy /s /i /q %PYTHON_EXE%\.. %INSTALL_DIR% || goto error
del %INSTALL_DIR%\lib\EXTERNALLY-MANAGED || goto error
set PYTHON=%INSTALL_DIR%\python.exe

rem Compile our requirements.txt into a locked form - don't need to save this
rem in the installation directory as we do on Linux, since Black Duck isn't
rem run on Windows
uv pip compile --python %PYTHON% --universal %SRC_DIR%\cb-dependencies.txt > requirements.txt || goto error

rem Remove pip and setuptools from cbpy
uv pip uninstall --python %PYTHON% pip setuptools || goto error

rem Install our desired dependencies
uv pip install --python %PYTHON% --no-build -r requirements.txt || goto error

rem Prune installation
cd %INSTALL_DIR%
rmdir /s /q Scripts || goto error
rmdir /s /q include || goto error
rmdir /s /q libs || goto error
rmdir /s /q tcl || goto error
cd Lib || goto error
rmdir /s /q ensurepip || goto error

rem Quick installation test
%INSTALL_DIR%\python.exe "%SRC_DIR%/test_cbpy.py" || goto error

goto :eof

:error
echo Failed with error %ERRORLEVEL%
exit /B %ERRORLEVEL%
