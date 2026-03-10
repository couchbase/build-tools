# Extracts the value of an annotation from the "build" project in the
# current manifest. Mirrors annot_from_manifest() in shell-utils.sh.
#
# Must be run from the repo root directory (where .repo/ lives).
# Outputs the annotation value to stdout, or the default value if not found.

param(
    [Parameter(Mandatory=$true)]
    [string]$AnnotationName,

    [string]$DefaultValue = ""
)

$ErrorActionPreference = "Stop"

$annot = $AnnotationName.ToUpper()

# Find the manifest. In a repo sync environment, .repo/manifest.xml is
# just a pointer — we need `repo manifest -r` to get the resolved
# manifest with annotations. Fall back to manifest.xml in CWD for
# source tarball builds.
if (Test-Path ".repo") {
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $manifestXml = & repo manifest -r 2>$null
    $repoExit = $LASTEXITCODE
    $ErrorActionPreference = $prevPref
    if ($repoExit -ne 0) {
        Write-Error "Failed to run 'repo manifest -r': $manifestXml"
        exit 3
    }
    [xml]$manifest = ($manifestXml | Out-String)
} elseif (Test-Path "manifest.xml") {
    [xml]$manifest = Get-Content "manifest.xml"
} else {
    Write-Error "No .repo/ or manifest.xml found in current directory"
    exit 3
}

$node = $manifest.SelectSingleNode(
    "//project[@name='build']/annotation[@name='$annot']/@value"
)

if ($node) {
    Write-Output $node.Value
} else {
    Write-Output $DefaultValue
}
