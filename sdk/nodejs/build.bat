set NODE_VER=%1
set ARCH=%2

set MSVSARCH=x86
if "%ARCH%"=="x64" set MSVSARCH=amd64

setlocal EnableDelayedExpansion

set HOME=C:\Users\Administrator
set TEMP=C:\Users\Administrator\AppData\Local\Temp\2
set TMP=C:\Users\Administrator\AppData\Local\Temp\2
set "PATH=C:\node-v%NODE_VER%;%PATH%"

cd couchnode

rem call "C:\Program Files (x86)\Microsoft Visual Studio\2017\Professional\VC\Auxiliary\Build\vcvarsall.bat" %MSVSARCH%

call npm update || goto error
call npm install --ignore-scripts --unsafe-perm || goto error
set npm_config_loglevel=silly
node .\node_modules\prebuild\bin.js -b %NODE_VER% --verbose --force || goto error

endlocal

goto :eof

:error
echo Failed with error %ERRORLEVEL%.
exit /b %ERRORLEVEL%

:eof
exit /b 0
