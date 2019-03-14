@echo on

set INSTALL_DIR=%1
set DEPS=%WORKSPACE%\deps

set SITE=https://packages.couchbase.com/cbdep/0.9.3/cbdep-0.9.3-windows.exe
set FILENAME=%WORKSPACE%\cbdep.exe
powershell -command "& { (New-Object Net.WebClient).DownloadFile('%SITE%', '%FILENAME%') }" || goto error
%WORKSPACE%\cbdep.exe install -d "%DEPS%" golang 1.11.5

set GOPATH=%WORKSPACE%
set PATH=%GOPATH%\deps\go1.11.5\bin;%PATH%

cd protoc-gen-go || goto error
go build || goto error

rem Copy right stuff to output directory.
mkdir %INSTALL_DIR%\bin || goto error
copy protoc-gen-go %INSTALL_DIR%\bin || goto error

goto :eof

:error
echo Failed with error %ERRORLEVEL%
exit /B %ERRORLEVEL%
