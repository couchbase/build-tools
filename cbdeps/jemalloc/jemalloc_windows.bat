setlocal
set PATH=%PATH%;c:\cygwin\bin

set INSTALL_DIR_WINPATH=%1
set ROOT_DIR=%2

rem Man, bat sucks.
for /F %%I in ('cygpath -m %INSTALL_DIR_WINPATH%') do @set "INSTALL_DIR=%%I"
for /F %%I in ('cygpath -m %ROOT_DIR%\build-tools\cbdeps\jemalloc') do @set "CBDEPS_DIR=%%I"

cd %ROOT_DIR%\jemalloc

rem Primary builds for Server
set configure_args=--with-jemalloc-prefix=je_ --disable-cache-oblivious --disable-zone-allocator --enable-prof --disable-cxx
sh "%CBDEPS_DIR%/win_build_jemalloc.sh" "%configure_args%" %INSTALL_DIR% "" || exit /b

rem Clean up output, so old .pdb files can't confuse next builds
git clean -dfx

rem Additional Release and Debug builds without je_ prefix.
rem Note: contrary to the doc, the default prefix appears to be "je_", not
rem "", so we have to explicitly set it to empty here.
set configure_args=--with-jemalloc-prefix=
sh "%CBDEPS_DIR%/win_build_jemalloc.sh" "%configure_args%" %INSTALL_DIR%/noprefix "_noprefix" || exit /b
