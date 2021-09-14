set INSTALL_DIR=%1
set ROOT_DIR=%2

cd %ROOT_DIR%\curl

set OUTPUT_DIR=builds\libcurl-vc17-x64-release-dll-ipv6-sspi-schannel

call .\buildconf.bat || goto error
cd winbuild
call nmake -f Makefile.vc mode=dll VC=17 MACHINE=x64 DEBUG=no GEN_PDB=yes || goto error

cd ..
xcopy %OUTPUT_DIR% %INSTALL_DIR% /s || goto error

goto :eof

:error
echo Failed with error %ERRORLEVEL%
exit /B %ERRORLEVEL%
