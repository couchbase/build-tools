#!/usr/bin/env pwsh

# Fix uninitialized variable warning that MSVC 2022 treats as error
# Replaces "AddressType high;" with "AddressType high = AddressType();"

$targetFile = "src\processor\range_map-inl.h"

Write-Host "Checking patch status for uninitialized variable in $targetFile"

if (!(Test-Path $targetFile)) {
    Write-Error "Target file $targetFile not found!"
    exit 1
}

try {
    $content = Get-Content $targetFile -Raw

    # Check if patch is already applied
    if ($content -match 'AddressType high = AddressType\(\);') {
        Write-Host "Patch already applied to $targetFile - skipping"
        exit 0
    }

    # Check if the original pattern exists
    if (!($content -match 'AddressType high;')) {
        Write-Host "Original pattern not found in $targetFile - patch may not be needed or file structure has changed"
        exit 0
    }

    # Apply the patch: Replace the uninitialized declaration with initialized version
    $content = $content -replace 'AddressType high;', 'AddressType high = AddressType();'

    Set-Content $targetFile $content -NoNewline

    Write-Host "Successfully applied patch to $targetFile"
} catch {
    Write-Error "Failed to apply patch: $_"
    exit 1
}