set NODE_VER=%1
set ARCH=%2

setlocal EnableDelayedExpansion

git clone https://github.com/couchbaselabs/cbsdkbb || goto error
git clone https://github.com/couchbase/couchnode || goto error

set HOME=C:\Users\Administrator
set TEMP=C:\Users\Administrator\AppData\Local\Temp\2
set TMP=C:\Users\Administrator\AppData\Local\Temp\2
set PYTHON="C:\Program Files\Python27\python.exe"

call %BBSDK%\common\env vc14 %ARCH% || goto error
call %BBSDK%\njs\env %NODE_VER% || goto error

set GYP_MSVS_VERSION=%MSVSYEAR%

call npm update || goto error
call npm install --ignore-scripts --unsafe-perm || goto error
set npm_config_loglevel=silly
node node_modules/prebuild/bin.js -b %NODE_VER% --verbose --force || goto error

endlocal

goto :eof

:error
echo Failed with error %ERRORLEVEL%.
exit /b %ERRORLEVEL%
