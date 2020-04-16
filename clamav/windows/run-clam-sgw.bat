set CLAMDIR=C:\clamav
set CLAM_FILENAME=clamav-%CLAMAV_VERSION%-win-x64-portable.zip
set CLAM_DL=%CLAMDIR%\downloads\%CLAM_FILENAME%
set CLAM_DB=%CLAMDIR%\database
set BUILD_TOOLS=%WORKSPACE%\build-tools\clamav\windows

mkdir %CLAMDIR%\downloads
if not exist %CLAM_DL% (
    curl --fail -L -o %CLAM_DL% https://www.clamav.net/downloads/production/%CLAM_FILENAME% || goto error
)
unzip %CLAM_DL%

mkdir %CLAM_DB%
freshclam --config-file=%BUILD_TOOLS%\freshclam.conf || goto error
echo ...........................................
echo ClamAV Version
clamscan -V
echo ...........................................
clamscan --database="%CLAM_DB%" --tempdir="C:\WINDOWS\Temp" --suppress-ok-results --log="%WORKSPACE%\scan.log" --recursive "C:\Program Files\Couchbase\Sync Gateway" || goto error

goto eof

:error
echo Failed with error %ERRORLEVEL%
exit /b %ERRORLEVEL%

:eof
exit /b 0
