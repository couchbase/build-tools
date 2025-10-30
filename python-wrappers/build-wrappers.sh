#!/bin/bash -e

UPLOAD=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --publish|--release)
            UPLOAD=true
            shift
            ;;
        *)
            TOOL_NAME="$1"
            shift
            ;;
    esac
done

if [ -z "$TOOL_NAME" ]; then
    echo "Usage: $0 [--publish|--release] <tool-name>"
    echo "Example: $0 patch_via_gerrit              # Build locally"
    echo "         $0 --publish patch_via_gerrit     # Build and publish to S3"
    exit 1
fi

echo "Building wrappers for ${TOOL_NAME}..."

# Create build directory if it doesn't exist
mkdir -p build

# Create Linux/Mac wrapper from template, replacing tool name
echo "Building Unix wrapper..."
sed "s/__TOOL_NAME__/${TOOL_NAME}/g" templates/wrapper-unix.sh > "build/${TOOL_NAME}"
chmod +x "build/${TOOL_NAME}"

# Build Windows wrapper from template
echo "Building Windows wrapper..."
sed "s/__TOOL_NAME__/${TOOL_NAME}/g" templates/wrapper-windows.go > "build/${TOOL_NAME}-windows.go"
GOOS=windows GOARCH=amd64 go build -o "build/${TOOL_NAME}-windows.exe" "build/${TOOL_NAME}-windows.go"
rm "build/${TOOL_NAME}-windows.go"

if [ "$UPLOAD" = true ]; then
    echo "Uploading Unix wrappers..."
    for unix in ${TOOL_NAME}-darwin ${TOOL_NAME}-darwin-arm64 ${TOOL_NAME}-darwin-x86_64 ${TOOL_NAME}-linux ${TOOL_NAME}-linux-aarch64 ${TOOL_NAME}-linux-x64-musl ${TOOL_NAME}-linux-x86_64; do
        aws s3 cp --acl public-read "build/${TOOL_NAME}" "s3://packages.couchbase.com/${TOOL_NAME}/$unix"
    done

    echo "Uploading Windows wrappers..."
    for win in ${TOOL_NAME}-windows-x86_64.exe ${TOOL_NAME}-windows.exe ${TOOL_NAME}-windows_x86_64.exe ${TOOL_NAME}.exe; do
        aws s3 cp --acl public-read "build/${TOOL_NAME}-windows.exe" "s3://packages.couchbase.com/${TOOL_NAME}/$win"
    done

    echo "Invalidating CloudFront cache..."
    aws cloudfront create-invalidation --distribution-id E1U7LG5JV48KNP --paths "/${TOOL_NAME}/*"

    echo "Published successfully!"
else
    echo "Build complete! Files are in the build/ directory"
    echo "To publish, run: $0 --publish ${TOOL_NAME}"
fi

