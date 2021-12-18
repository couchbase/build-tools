# For some reason we need to remember this
$PWD=Get-Location

# Read build coordinates from command line or environment
$PRODUCT=$args[0]
if ($PRODUCT -eq $null) {
    $PRODUCT = $Env:PRODUCT
    $RELEASE = $Env:RELEASE
    $VERSION = $Env:VERSION
    $BLD_NUM = $Env:BLD_NUM
} else {
    $RELEASE = $args[1]
    $VERSION = $args[2]
    $BLD_NUM = $args[3]
}

# Error check
if (! $PRODUCT) {
    throw "PRODUCT missing!"
}
if (! $RELEASE) {
    throw "RELEASE missing!"
}
if (! $VERSION) {
    throw "VERSION missing!"
}
if (! $BLD_NUM) {
    throw "BLD_NUM missing!"
}

# Wait for 10 minutes at most before breaking the loop
# It should be sufficent for build database and blackduck scan to finish.

while($true -and ($counter++ -lt 60))
{
    try {
        $BUILD_METADATA = Invoke-WebRequest "http://dbapi.build.couchbase.com:8000/v1/builds/$PRODUCT-$VERSION-$BLD_NUM/metadata"
    }
    catch {
        Write-Host "$PRODUCT-$VERSION-$BLD_NUM is not in the build database yet..."
        sleep 10
        continue
    }
    $BD_RESULT=($BUILD_METADATA | ConvertFrom-Json).data.blackduck_scan
    if ($BD_RESULT -like '*pass*') {
        Write-Host "Download blackduck scan's notices.txt to $PWD\notices.txt"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        (New-Object Net.WebClient).DownloadFile("https://github.com/couchbase/product-metadata/blob/master/$PRODUCT/blackduck/$VERSION/notices.txt", "$PWD\notices.txt")
        exit
    } elseif ($BD_RESULT -like '*fail*') {
        Write-Host "Blackduck scan failed, notices.txt won't be downloaded."
        exit 1
    } else {
        Write-Host "Waiting for blackduck scan to finish..."
        sleep 10
    }
}

Write-Host "Timed out waiting for notices.txt, failing..."
exit 1
