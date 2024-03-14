<#
.SYNOPSIS
    A tool for pushing Couchbase Lite nuget packages to Nuget
.DESCRIPTION
    This tool will download the nuget packages from S3, and then push them all to Nuget
.PARAMETER Product
    The product to release, i.e. couchbase-lite-net, couchbase-lite-net-extensions.
.PARAMETER Version
    The version of the library to download from S3
.PARAMETER AccessKey
    The AWS access key
.PARAMETER SecretKey
    The AWS secret key
.PARAMETER NugetApiKey
    The API key for pushing to the Nuget feed
.PARAMETER DryRun
    Perform all steps except for the actual Nuget feed push
.EXAMPLE
    C:\PS> .\PushBuild.ps1 -Product couchbase-lite-net -Version 3.2.0 -AccessKey <key> -SecretKey <key> -NugetApiKey <key>
    Pushes the official couchbase-lite-net 3.2.0 packages to nuget.org
#>
[CmdletBinding(DefaultParameterSetName='set2')]
param(
    [Parameter(ParameterSetName='set2', Mandatory=$true, HelpMessage="The product to release")][string]$Product,
    [Parameter(ParameterSetName='set2', Mandatory=$true, HelpMessage="The version to download from S3")][string]$Version,
    [Parameter(ParameterSetName='set2', Mandatory=$true, HelpMessage="The access key of the AWS credentials")][string]$AccessKey,
    [Parameter(ParameterSetName='set2', Mandatory=$true, HelpMessage="The secret key of the AWS credentials")][string]$SecretKey,
    [Parameter(ParameterSetName='set2', Mandatory=$true, HelpMessage="The API key for pushing to the Nuget feed")]
    [Parameter(ParameterSetName='set1', Mandatory=$true, HelpMessage="The API key for pushing to the Nuget feed")][string]$NugetApiKey,
    [Parameter(ParameterSetName='set2')][switch]$DryRun
)

Write-Host "Downloading packages from S3..."
Read-S3Object -BucketName packages.couchbase.com -KeyPrefix releases/${Product}/${Version} -Folder . -AccessKey $AccessKey -SecretKey $SecretKey
$NugetUrl = "https://api.nuget.org/v3/index.json"

if(-Not $(Test-Path .\nuget.exe) -and -not $DryRun) {
    Invoke-WebRequest https://dist.nuget.org/win-x86-commandline/v5.5.1/nuget.exe -OutFile nuget.exe
}

foreach($file in (Get-ChildItem $pwd -Filter *.nupkg)) {
    if($DryRun) {
        Write-Host "DryRun specified, skipping push for $file"
    } else {
        & .\nuget.exe push $file -ApiKey $NugetApiKey -Source $NugetUrl
    }
}
