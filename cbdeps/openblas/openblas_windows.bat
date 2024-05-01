rem For now at least, Server and Lite want the same things
powershell -File %~dp0\openblas_lite_windows.ps1 -InstallDir %1 -RootDir %2 -Arch %8
