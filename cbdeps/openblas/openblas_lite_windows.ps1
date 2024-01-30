<#
.SYNOPSIS
    A script for the Couchbase official build servers to use to build OpenBLAS for Windows
.DESCRIPTION
    This script will build OpenBLAS for 64-bit editions of Windows (currently x86_64 and arm64)
.PARAMETER InstallDir
    The directory to install the final output into
.PARAMETER RootDir
    The top level workspace that this script is meant to operate in
.PARAMETER Architectures
    The architectures to build (x86_64, arm64, or both)
#>

param(
    [Parameter(Mandatory=$true, HelpMessage="The directory to install the final output into")][string]$InstallDir,
    [Parameter(Mandatory=$true, HelpMessage="The top level workspace that this script is meant to operate in")][string]$RootDir,
    [Parameter(Mandatory=$true, HelpMessage="The architecture to build (x86_64 or arm64)")][string]$Arch
)

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

$VS_VER=$(& 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe' -latest -requires Microsoft.VisualStudio.Component.VC.Llvm.Clang -property catalog_productLineVersion)
if($VS_VER -ne "2022") {
    if(-Not $VS_VER) {
        throw "No Visual Studio detected with clang-cl, giving up..."
    }

    throw "clang-cl found, but Visual Studio version invalid ($VS_VER)"
}

if(-Not (& where.exe cbdep)) {
    throw "Unable to find cbdep.exe!"
}

$CMAKE_VER="3.28.1"
$NINJA_VER="1.10.1"

New-Item -ItemType Directory -Path $RootDir/openblas/build_$Arch -ErrorAction Ignore
New-Item -ItemType Directory -Path $RootDir/tools/ -ErrorAction Ignore

$CMAKE="$RootDir/tools/cmake-${CMAKE_VER}/bin/cmake.exe"
if(-Not (Test-Path $CMAKE)) {
    Write-Host
    Write-Host " ======== Installing cmake ========"
    Write-Host
    & $RootDir/tools/cbdep.exe install -d $RootDir/tools cmake ${CMAKE_VER}
}

$NINJA="$RootDir/tools/ninja-${NINJA_VER}/bin/ninja.exe"
if(-Not (Test-Path $NINJA)) {
    Write-Host
    Write-Host " ======== Installing ninja ========"
    Write-Host
    & $RootDir/tools/cbdep.exe install -d $RootDir/tools ninja ${NINJA_VER}
}

Write-Host
Write-Host "====  Building Windows $Arch binary ==="
Write-Host

Push-Location $RootDir/openblas/build_$Arch
if($Arch -eq "arm64") {
    & $CMAKE `
    -G Ninja `
    -DNOFORTRAN=ON `
    -DCMAKE_CROSSCOMPILING=ON `
    -DCMAKE_SYSTEM_NAME="Windows" `
    -DARCH=arm64 `
    -DBINARY=64 `
    -DCMAKE_SYSTEM_PROCESSOR=ARM64 `
    -DCMAKE_C_COMPILER_TARGET=arm64-pc-windows-msvc `
    -DCMAKE_ASM_COMPILER_TARGET=arm64-pc-windows-msvc `
    -DCMAKE_C_COMPILER=clang-cl `
    -DCMAKE_MAKE_PROGRAM="$NINJA" `
    -DBUILD_WITHOUT_LAPACK=0 `
    -DDYNAMIC_ARCH=0 `
    -DBUILD_LAPACK_DEPRECATED=0 `
    -DBUILD_WITHOUT_CBLAS=1 `
    -DCMAKE_BUILD_TYPE=Release `
    -DCMAKE_INSTALL_PREFIX="$InstallDir" `
    -S ..
} else {
    & $CMAKE `
    -G Ninja `
    -DNOFORTRAN=ON `
    -DCMAKE_C_COMPILER=clang-cl `
    -DCMAKE_MAKE_PROGRAM="$NINJA" `
    -DBUILD_WITHOUT_LAPACK=0 `
    -DDYNAMIC_ARCH=1 `
    -DDYNAMIC_LIST="EXCAVATOR;HASWELL;ZEN;SKYLAKEX;COOPERLAKE;SAPPHIRERAPIDS" `
    -DBUILD_LAPACK_DEPRECATED=0 `
    -DBUILD_WITHOUT_CBLAS=1 `
    -DCMAKE_BUILD_TYPE=Release `
    -DCMAKE_INSTALL_PREFIX="$InstallDir" `
    -S ..
}

function FilterCompileOutput {
    param(
        [Parameter(Mandatory=$true)][string]
        $line
    )

    if($line.StartsWith("[")) {
        Write-Host $line
    } else {
        Add-Content -Path $RootDir/build.err -Value $line
    }
}

if(Test-Path $RootDir/build.err) {
    Remove-Item $RootDir/build.err
}

New-Item -ItemType File $RootDir/build.err
& $NINJA install | ForEach-Object { FilterCompileOutput -line $_}