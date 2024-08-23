@echo off

setlocal enabledelayedexpansion

rmdir /s /q deps
mkdir deps

pushd deps
curl -LO https://packages.couchbase.com/cbdep/cbdep-windows.exe
for /f "delims=" %%A in ('curl -s "https://raw.githubusercontent.com/couchbaselabs/golang/main/versions/SUPPORTED_NEWER.txt"') do (
  set "short_version=!new_version!%%A!linefeed!"
)
for /f "delims=" %%A in ('curl -s "https://raw.githubusercontent.com/couchbaselabs/golang/main/versions/%short_version%.txt"') do (
  set "go_version=!new_version!%%A!linefeed!"
)
call cbdep-windows.exe install -d . golang %go_version%
set PATH=%CD%\go%go_version%\bin;%PATH%
popd

go build -ldflags="-s -w" -o repo.exe main.go
