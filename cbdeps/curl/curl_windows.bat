set INSTALL_DIR=%1
set ROOT_DIR=%2

set OPENSSL_VER=1.1.1k-3

set CBDEPS_DIR=%ROOT_DIR%\cbdeps

mkdir %CBDEPS_DIR%
cd %CBDEPS_DIR%

curl -L https://packages.couchbase.com/cbdep/1.0.1/cbdep-1.0.1-windows.exe -o cbdep.exe || goto error
cbdep.exe install -d %CBDEPS_DIR% openssl %OPENSSL_VER% || goto error

cd %ROOT_DIR%\curl

set OUTPUT_DIR=builds\libcurl-vc15-x64-release-dll-ssl-dll-ipv6-sspi

rem Fix that wasn't in 7.66.0 - probably needs to be removed
rem when building later versions
git cherry-pick a765a305 || goto error

call .\buildconf.bat || goto error
cd winbuild
call nmake -f Makefile.vc mode=dll VC=15 MACHINE=x64 DEBUG=no GEN_PDB=yes WITH_SSL=dll WITH_DEVEL=%CBDEPS_DIR%/openssl-%OPENSSL_VER%|| goto error

cd ..
xcopy %OUTPUT_DIR% %INSTALL_DIR% /s || goto error

goto :eof

:error
echo Failed with error %ERRORLEVEL%
exit /B %ERRORLEVEL%
