@echo off

if not "%~1"=="" (
    set PRODUCT=%1
    set RELEASE=%2
    set VERSION=%3
    set BLD_NUM=%4
)

if  "%PRODUCT%"=="" (
    echo Missing PRODUCT
    exit /b 1
)
if  "%RELEASE%"=="" (
    echo Missing RELEASE
    exit /b 1
)
if  "%VERSION%"=="" (
    echo Missing VERSION
    exit /b 1
)
if  "%BLD_NUM%"=="" (
    echo Missing BLD_NUM
    exit /b 1
)

echo Downloading properties for %PRODUCT% %RELEASE% %VERSION%-%BLD_NUM%...
set ROOT=http://latestbuilds.service.couchbase.com/builds/latestbuilds/%PRODUCT%/%RELEASE%/%BLD_NUM%
set PROP=%PRODUCT%-%RELEASE%-%BLD_NUM%.properties
powershell -command "& { (New-Object Net.WebClient).DownloadFile('%ROOT%/%PROP%', 'build.properties') }" || goto error

echo Downloading source for %PRODUCT% %RELEASE% %VERSION%-%BLD_NUM%...
set SRC=%PRODUCT%-%VERSION%-%BLD_NUM%-source.tar.gz
powershell -command "& { (New-Object Net.WebClient).DownloadFile('%ROOT%/%SRC%', '%SRC%') }" || goto error

echo Extracting source...
cmake -E tar xzf %SRC% || goto error

goto eof

:error
echo Failed with error %ERRORLEVEL%.
exit /b %ERRORLEVEL%

:eof
exit /b 0