@echo on

set INSTALL_DIR=%1
set ROOT_DIR=%2

cd %ROOT_DIR%

set DEPS=%WORKSPACE%\deps

set CBDEP_TOOL_VER=1.1.6

set SCRIPT_DIR=%~dp0

rem Determine Go version from manifest annotation (matching gover_from_manifest in shell-utils.sh)
for /f "delims=" %%i in ('powershell -ExecutionPolicy Bypass -File "%SCRIPT_DIR%\..\..\utilities\windows\gover_from_manifest.ps1"') do set GO_VER=%%i
if not defined GO_VER (
    echo Could not determine Go version from manifest
    exit /B 1
)
echo Using Go version %GO_VER%

set SITE=https://packages.couchbase.com/cbdep/%CBDEP_TOOL_VER%/cbdep-%CBDEP_TOOL_VER%-windows.exe
set FILENAME=%WORKSPACE%\cbdep.exe
powershell -command "& { (New-Object Net.WebClient).DownloadFile('%SITE%', '%FILENAME%') }" || goto error
%WORKSPACE%\cbdep.exe install -d "%DEPS%" golang %GO_VER%

set GOPATH=%WORKSPACE%
set PATH=%GOPATH%\deps\go%GO_VER%\bin;%PATH%

cd %ROOT_DIR%\protoc-gen-go\cmd\protoc-gen-go || goto error
go build || goto error

rem Copy right stuff to output directory.
mkdir %INSTALL_DIR%\bin || goto error
copy protoc-gen-go.exe %INSTALL_DIR%\bin || goto error

goto :eof

:error
echo Failed with error %ERRORLEVEL%
exit /B %ERRORLEVEL%
