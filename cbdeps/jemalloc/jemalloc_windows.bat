setlocal
set PATH=%PATH%;c:\cygwin\bin

set INSTALL_DIR_WINPATH=%1
set ROOT_DIR=%2

rem Man, bat sucks.
for /F %%I in ('cygpath -m %INSTALL_DIR_WINPATH%') do @set "INSTALL_DIR=%%I"
for /F %%I in ('cygpath -m %ROOT_DIR%\build-tools\cbdeps\jemalloc\scripts') do @set "JEMALLOC_SCRIPTS_DIR=%%I"

rem Primary builds for Server
set configure_args=--with-jemalloc-prefix=je_ --disable-cache-oblivious --disable-zone-allocator --enable-prof --disable-cxx
sh "%JEMALLOC_SCRIPTS_DIR%/win_build_jemalloc.sh" "%ROOT_DIR%" "%configure_args%" %INSTALL_DIR% "" || exit /b
