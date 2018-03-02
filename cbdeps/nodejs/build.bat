set NODE_VER=%1
set ARCH=%2

set FILENAME=node-v%NODE_VER%-win-%ARCH%.zip
set SITE=https://nodejs.org/dist/v%NODE_VER%/%FILENAME%
powershell -command "& { (New-Object Net.WebClient).DownloadFile('%SITE%', '%FILENAME%') }" || goto error

7z x %FILENAME% -oC:\ || goto error
rename C:\node-v%NODE_VER%-win-%ARCH% node-v%NODE_VER% || goto error

rem Add unpacked nodeJS to path to install node-gyp
set PATH=C:\node-v%NODE_VER%;%PATH%

rem Install node-gyp; this will be placed in the nodeJS dependency tree
call npm install -g node-gyp || goto error

rem Create zipfile and delete unpacked tarball
7z a node-%NODE_VER%-cb1-windows-%ARCH%.zip C:\node-v%NODE_VER% || goto error
rmdir /s /q C:\node-v%NODE_VER% || goto error

goto :eof

:error
echo Failed with error %ERRORLEVEL%.
exit /b %ERRORLEVEL%

:eof
exit /b 0
