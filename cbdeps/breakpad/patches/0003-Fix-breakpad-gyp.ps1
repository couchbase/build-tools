# Fix Breakpad .gyp files for Visual Studio 2022 compatibility
# This script addresses deprecation warnings

Write-Host "Fixing crash_generation.gyp..."
$crashgen = Get-Content '.\src\client\windows\crash_generation\crash_generation.gyp' -Raw
$crashgen = $crashgen -replace "(?s)('target_name': 'crash_generation_server',.*?'type': 'static_library',)", "`$1`r`n      'defines': ['_SILENCE_ALL_MS_EXT_DEPRECATION_WARNINGS'],"
$crashgen = $crashgen -replace "(?s)('target_name': 'crash_generation_client',.*?'type': 'static_library',)", "`$1`r`n      'defines': ['_SILENCE_ALL_MS_EXT_DEPRECATION_WARNINGS'],"
Set-Content '.\src\client\windows\crash_generation\crash_generation.gyp' $crashgen

Write-Host "Fixing exception_handler.gyp..."
$exceptionhandler = Get-Content '.\src\client\windows\handler\exception_handler.gyp' -Raw
$exceptionhandler = $exceptionhandler -replace "(?s)('target_name': 'exception_handler',.*?'type': 'static_library',)", "`$1`r`n      'defines': ['_SILENCE_ALL_MS_EXT_DEPRECATION_WARNINGS'],"
Set-Content '.\src\client\windows\handler\exception_handler.gyp' $exceptionhandler

Write-Host "Fixing crash_report_sender.gyp..."
$crashsender = Get-Content '.\src\client\windows\sender\crash_report_sender.gyp' -Raw
$crashsender = $crashsender -replace "(?s)('target_name': 'crash_report_sender',.*?'type': 'static_library',)", "`$1`r`n      'defines': ['_SILENCE_ALL_MS_EXT_DEPRECATION_WARNINGS'],"
Set-Content '.\src\client\windows\sender\crash_report_sender.gyp' $crashsender

Write-Host "Fixing Windows-specific testing.gyp..."
$wintesting = Get-Content '.\src\client\windows\unittests\testing.gyp' -Raw
$wintesting = $wintesting -replace "(?s)('target_name': 'gtest',.*?'type': 'static_library',)", "`$1`r`n      'defines': ['_SILENCE_ALL_MS_EXT_DEPRECATION_WARNINGS'],"
$wintesting = $wintesting -replace "(?s)('target_name': 'gmock',.*?'type': 'static_library',)", "`$1`r`n      'defines': ['_SILENCE_ALL_MS_EXT_DEPRECATION_WARNINGS'],"
Set-Content '.\src\client\windows\unittests\testing.gyp' $wintesting

Write-Host "Fixing client_tests.gyp..."
$clienttests = Get-Content '.\src\client\windows\unittests\client_tests.gyp' -Raw
$clienttests = $clienttests -replace "(?s)('target_name': 'processor_bits',.*?'type': 'static_library',)", "`$1`r`n      'defines': ['_SILENCE_ALL_MS_EXT_DEPRECATION_WARNINGS'],"
Set-Content '.\src\client\windows\unittests\client_tests.gyp' $clienttests

Write-Host "GYP file fixes completed successfully."
