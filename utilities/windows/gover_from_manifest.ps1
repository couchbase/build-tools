# Determines the Go version to use from the build manifest.
# Mirrors the logic of gover_from_manifest() in shell-utils.sh.
#
# Must be run from the repo root directory (where .repo/ lives).
# Outputs the resolved Go version (e.g. "1.22.3") to stdout.

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$annotScript = Join-Path $scriptDir "annot_from_manifest.ps1"

# The annotation is spelled two different ways in different products'
# manifests (CBD-5117). Try GOVERSION first, then GO_VERSION.
$goVersion = & $annotScript -AnnotationName "GOVERSION"
if (-not $goVersion) {
    $goVersion = & $annotScript -AnnotationName "GO_VERSION"
}

if (-not $goVersion) {
    Write-Error "No GOVERSION or GO_VERSION annotation found in manifest"
    exit 1
}

# If it's already a fully-specified X.Y.Z version, use it as-is.
if ($goVersion -match '^\d+\.\d+\.\d+$') {
    Write-Output $goVersion
    exit 0
}

# Otherwise, resolve via the golang repo's version files.
if (-not (Test-Path "golang")) {
    # Get the resolved manifest to find the golang repo revision
    if (Test-Path ".repo") {
        $prevPref = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $manifestXml = & repo manifest -r 2>$null
        $ErrorActionPreference = $prevPref
        [xml]$manifest = ($manifestXml | Out-String)
    } elseif (Test-Path "manifest.xml") {
        [xml]$manifest = Get-Content "manifest.xml"
    } else {
        Write-Error "No .repo/ or manifest.xml found - cannot determine golang revision"
        exit 1
    }
    $golangSha = $manifest.SelectSingleNode(
        "//project[@name='golang']/@revision"
    ).Value
    git clone https://github.com/couchbaselabs/golang 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to clone golang repository"
        exit 1
    }
    git -C golang checkout $golangSha 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to checkout golang revision $golangSha"
        exit 1
    }
}

# If SUPPORTED_NEWER or SUPPORTED_OLDER, resolve to a major version first.
if ($goVersion -match 'SUPPORTED_') {
    $versionFile = "golang/versions/$goVersion.txt"
    if (-not (Test-Path $versionFile)) {
        Write-Error "Version file $versionFile not found"
        exit 1
    }
    $goVersion = (Get-Content $versionFile -First 1).Trim()
}

# Resolve the major version (e.g. 1.22) to a full X.Y.Z version.
$versionFile = "golang/versions/$goVersion.txt"
if (-not (Test-Path $versionFile)) {
    Write-Error "Specified GOVERSION $goVersion is not supported!!"
    exit 5
}
$goVersion = (Get-Content $versionFile -First 1).Trim()

Write-Output $goVersion
