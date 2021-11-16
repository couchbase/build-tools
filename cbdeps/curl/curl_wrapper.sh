#!/bin/bash -e

D0=$(cd "$(dirname "$0")" && pwd)

# Wrapper to search for the distro-provided certificate bundle. Uses the
# same hunt algorithm as Golang:
# https://golang.org/src/crypto/x509/root_linux.go
cert_files=(
    "/etc/ssl/certs/ca-certificates.crt"                # Debian/Ubuntu/Gentoo etc.
    "/etc/pki/tls/certs/ca-bundle.crt"                  # Fedora/RHEL 6
    "/etc/ssl/ca-bundle.pem"                            # OpenSUSE
    "/etc/pki/tls/cacert.pem"                           # OpenELEC
    "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem" # CentOS/RHEL 7
    "/etc/ssl/cert.pem"                                 # Alpine Linux
)
for cert_file in ${cert_files[@]}; do
    if [ -e "${cert_file}" ]; then
        export CURL_CA_BUNDLE=${cert_file}
        break
    fi
done

exec "${D0}/curl.real" "$@"
