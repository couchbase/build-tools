@echo on

set INSTALL_DIR=%1
set ROOT_DIR=%2

cd %ROOT_DIR%\protoc-gen-go

set DEPS=%WORKSPACE%\deps

set CBDEP_TOOL_VER=0.9.12
set GO_VER=1.13.8

set SITE=https://packages.couchbase.com/cbdep/%CBDEP_TOOL_VER%/cbdep-%CBDEP_TOOL_VER%-windows.exe
set FILENAME=%WORKSPACE%\cbdep.exe
powershell -command "& { (New-Object Net.WebClient).DownloadFile('%SITE%', '%FILENAME%') }" || goto error
%WORKSPACE%\cbdep.exe install -d "%DEPS%" golang %GO_VER%

set GOPATH=%WORKSPACE%
set PATH=%GOPATH%\deps\go%GO_VER%\bin;%PATH%

cd protoc-gen-go || goto error
go build || goto error

rem Copy right stuff to output directory.
mkdir %INSTALL_DIR%\bin || goto error
copy protoc-gen-go.exe %INSTALL_DIR%\bin || goto error

goto :eof

:error
echo Failed with error %ERRORLEVEL%
exit /B %ERRORLEVEL%
