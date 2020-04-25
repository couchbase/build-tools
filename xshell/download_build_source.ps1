# Abort on any error
$ErrorActionPreference = "Stop"

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

# Derived values
$PRODUCT_NAME = $PRODUCT.Split("::")[-1]
$PRODUCT_PATH = $PRODUCT -replace '::','/'
$ROOT = "http://latestbuilds.service.couchbase.com/builds/latestbuilds/$PRODUCT_PATH/$RELEASE/$BLD_NUM"

# Downloads
$PROP = "$PRODUCT_NAME-$RELEASE-$BLD_NUM.properties"
echo "Downloading $PROP..."
(New-Object Net.WebClient).DownloadFile("$ROOT/$PROP", "$PWD\build.properties")

$SRC = "$PRODUCT_NAME-$VERSION-$BLD_NUM-source.tar.gz"
echo "Downloading $SRC..."
(New-Object Net.WebClient).DownloadFile("$ROOT/$SRC", "$PWD\$SRC")

echo "Extracting source..."
cmake -E tar xzf $SRC
