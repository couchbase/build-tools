set PROFILE=%4

if "%PROFILE%" == "lite" (
    powershell -File %~dp0\openblas_lite_windows.ps1 -InstallDir %1 -RootDir %2 -Arch %8
) else (
    echo "ERROR: Unrecognized profile %PROFILE%"
    exit 1
)