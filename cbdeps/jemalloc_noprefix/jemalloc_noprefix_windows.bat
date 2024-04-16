setlocal
set PATH=%PATH%;c:\cygwin\bin

set INSTALL_DIR_WINPATH=%1
set ROOT_DIR=%2

rem Man, bat sucks.
for /F %%I in ('cygpath -m %INSTALL_DIR_WINPATH%') do @set "INSTALL_DIR=%%I"
for /F %%I in ('cygpath -m %ROOT_DIR%\build-tools\cbdeps\jemalloc\scripts') do @set "JEMALLOC_SCRIPTS_DIR=%%I"

rem Noprefix builds with no je_ prefix.
rem Note: contrary to the doc, the default prefix appears to be "je_", not
rem "", so we have to explicitly set it to empty here.
set configure_args=--with-jemalloc-prefix=
sh "%JEMALLOC_SCRIPTS_DIR%/win_build_jemalloc.sh" "%ROOT_DIR%" "%configure_args%" %INSTALL_DIR% "_noprefix" || exit /b
