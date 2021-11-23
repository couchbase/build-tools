set INSTALL_DIR=%1

set SCRIPTPATH=%cd%

rem Get Google's depot_tools.
if not exist depot_tools (
    git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git || goto error
    rem checkout specific commit id near v8 9.7.37
    rem newer changes has a chance of breaking the build
    cd depot_tools
    git checkout 5ba5119227002ab191b0f916df435b7410c4ca3c
    cd ..
)
set PATH=%cd%\depot_tools;%PATH%

rem Setting MSVC version specifically to 2019
set GYP_MSVS_VERSION=2019

rem Disable gclient getting Google-internal versions of stuff
set DEPOT_TOOLS_WIN_TOOLCHAIN=0

rem Set up gclient config for tag to pull for v8, then do sync
rem (this handles the 'fetch v8' done by the usual process)
echo solutions = [ { "url": "https://github.com/couchbasedeps/v8-mirror.git@9.7.37","managed": False, "name": "v8", "deps_file": "DEPS", }, ]; > .gclient
call gclient sync || goto error

echo on

cd v8
rem Apply necessary changes so that v8 can be built with MSVC.
rem A few cppgc unittests are broken and have to be commented out due to recent changes in v8/include/cppgc/internal/pointer-policies.h
call git apply --ignore-whitespace %SCRIPTPATH%\windows_patches\v8.patch
cd build
call git apply --ignore-whitespace %SCRIPTPATH%\windows_patches\build.patch

rem Actual v8 configure and build steps - we build debug and release.
cd ..
rem Use double-quoting here because .bat quote removal is inscrutable.
set V8_ARGS=target_cpu=""x64"" is_component_build=true v8_enable_backtrace=true v8_use_external_startup_data=false v8_enable_pointer_compression=false is_clang=false treat_warnings_as_errors=false use_custom_libcxx=false v8_enable_verify_heap=false

call gn gen out.gn/x64.release --args="%V8_ARGS% is_debug=false" || goto error

echo on
call ninja -C out.gn/x64.release || goto error
echo on
call gn gen out.gn/x64.debug --args="%V8_ARGS% is_debug=true symbol_level=1" || goto error
echo on
call ninja -C out.gn/x64.debug || goto error
echo on

rem Copy right stuff to output directory.
mkdir %INSTALL_DIR%\lib\Release
mkdir %INSTALL_DIR%\lib\Debug
mkdir %INSTALL_DIR%\include\libplatform
mkdir %INSTALL_DIR%\include\unicode

cd out.gn\x64.release
copy v8.dll* %INSTALL_DIR%\lib\Release || goto error
copy v8_lib* %INSTALL_DIR%\lib\Release || goto error
copy icu*.* %INSTALL_DIR%\lib\Release || goto error
copy zlib.dll* %INSTALL_DIR%\lib\Release || goto error
del %INSTALL_DIR%\lib\Release\*.exp || goto error
del %INSTALL_DIR%\lib\Release\*.ilk || goto error

cd ..\..\out.gn\x64.debug
copy v8.dll* %INSTALL_DIR%\lib\Debug || goto error
copy v8_lib* %INSTALL_DIR%\lib\Debug || goto error
copy icu*.* %INSTALL_DIR%\lib\Debug || goto error
copy zlib.dll* %INSTALL_DIR%\lib\Debug || goto error
del %INSTALL_DIR%\lib\Debug\*.exp || goto error
del %INSTALL_DIR%\lib\Debug\*.ilk || goto error

cd ..\..\include
copy v8*.h %INSTALL_DIR%\include || goto error
cd libplatform
copy *.h %INSTALL_DIR%\include\libplatform || goto error

cd ..\..\third_party\icu\source\common\unicode
copy *.h %INSTALL_DIR%\include\unicode || goto error
cd ..\..\io\unicode
copy *.h %INSTALL_DIR%\include\unicode || goto error
cd ..\..\i18n\unicode
copy *.h %INSTALL_DIR%\include\unicode || goto error
cd ..\..\extra\uconv\unicode
copy *.h %INSTALL_DIR%\include\unicode || goto error

goto :eof

:error
echo Failed with error %ERRORLEVEL%
exit /B %ERRORLEVEL%
