set INSTALL_DIR=%1
set ROOT_DIR=%2
set SCRIPTPATH=%cd%

echo on

rem

rem Build gn.
cd %ROOT_DIR%\gn
python3 build/gen.py
ninja -C out
set PATH=%CD%/out;%PATH%

rem Install specific Windows SDK, if necessary.
cd %ROOT_DIR%
if not exist "C:\Program Files (x86)\Windows Kits\10\Include\10.0.20348.0" (
    curl -L -o winsdk.exe https://go.microsoft.com/fwlink/?linkid=2164145 || goto error
    start /wait .\winsdk.exe /l winsdk-install.log /q /features OptionId.WindowsDesktopDebuggers OptionId.DesktopCPPx64
)

rem Install Google's clang. It's just easier than making it use MSVC directly.
cd v8
python3 tools\clang\scripts\update.py

rem Recreate a couple droppings that would have been created by gclient
echo # > build\config\gclient_args.gni
python3 build\util\lastchange.py -o build/util/LASTCHANGE || goto error

rem Fix their bundled ICU's buggy script
copy /Y %SCRIPTPATH%\windows_patches\asm_to_inline_asm.py third_party\icu\scripts

rem Fix their coding error
call git apply --ignore-whitespace %SCRIPTPATH%\windows_patches\logging_cctype.patch

rem Tell gn we want to use our own compiler
set DEPOT_TOOLS_WIN_TOOLCHAIN=0

rem Actual v8 configure and build steps - we build debug and release.
rem Ideally this set of args should match the corresponding set in
rem v8_unix.sh.

set V8_ARGS=use_custom_libcxx=false is_component_build=true v8_enable_backtrace=true v8_use_external_startup_data=false v8_enable_pointer_compression=false treat_warnings_as_errors=false icu_use_data_file=false

call gn gen out-release --args="%V8_ARGS% is_debug=false" || goto error

echo on
call ninja -C out-release v8 || goto error
echo on
call gn gen out-debug --args="%V8_ARGS% is_debug=true v8_optimized_debug=true symbol_level=1 v8_enable_slow_dchecks=true" || goto error
echo on
call ninja -C out-debug v8 || goto error
echo on

rem Uninstall SDK if we installed it ourselves.
if exist %ROOT_DIR%\winsdk.exe (
    start /wait %ROOT_DIR%\winsdk.exe /q /uninstall || goto error
)

rem Copy right stuff to output directory.
mkdir %INSTALL_DIR%\lib\Release
mkdir %INSTALL_DIR%\lib\Debug
mkdir %INSTALL_DIR%\include\cppgc
mkdir %INSTALL_DIR%\include\cppgc\internal
mkdir %INSTALL_DIR%\include\libplatform
mkdir %INSTALL_DIR%\include\unicode

cd out-release
copy v8.dll* %INSTALL_DIR%\lib\Release || goto error
copy v8_lib*.dll* %INSTALL_DIR%\lib\Release || goto error
copy icu*.dll* %INSTALL_DIR%\lib\Release || goto error
copy zlib.dll* %INSTALL_DIR%\lib\Release || goto error

cd ..\out-debug
copy v8.dll* %INSTALL_DIR%\lib\Debug || goto error
copy v8_lib*.dll* %INSTALL_DIR%\lib\Debug || goto error
copy icu*.dll* %INSTALL_DIR%\lib\Debug || goto error
copy zlib.dll* %INSTALL_DIR%\lib\Debug || goto error

cd ..\include
copy v8*.h %INSTALL_DIR%\include || goto error
cd libplatform
copy *.h %INSTALL_DIR%\include\libplatform || goto error
cd ..\cppgc
copy *.h %INSTALL_DIR%\include\cppgc
cd internal
copy *.h %INSTALL_DIR%\include\cppgc\internal

cd ..\..\..\third_party\icu\source\common\unicode
copy *.h %INSTALL_DIR%\include\unicode || goto error
cd ..\..\io\unicode
copy *.h %INSTALL_DIR%\include\unicode || goto error
cd ..\..\i18n\unicode
copy *.h %INSTALL_DIR%\include\unicode || goto error
cd ..\..\extra\uconv\unicode
copy *.h %INSTALL_DIR%\include\unicode || goto error

rem Fix unistr.h. This problem is caused by compiling icu with clang and
rem then building Server with MSVC. ICU's UnicodeString class is
rem reasonably declared __declspec(dllimport) for Server builds, which
rem means all functions in that class are also __declspec(dllimport).
rem UnicodeString also has a number of inline functions. Unfortunately
rem MSVC has a special feature that effectively allows a DLL to include
rem a pre-compiled definition for inline functions, which is clever and
rem all, but clang doesn't do that. So our libicui18n.dll doesn't have
rem those pre-compiled bits, leading to a link-time error in the Server
rem build. Fortunately, at least currently, re-specifying all those
rem inline functions with the (also MSVC-specific) "__forceinline"
rem declaration allows Server to build. This script hacks unistr.h in
rem the final package for use by MSVC.
cd %INSTALL_DIR%\include\unicode
python3 %SCRIPTPATH%\windows_patches\fix-unistr.py

goto :eof

:error
echo Failed with error %ERRORLEVEL%
exit /B %ERRORLEVEL%
