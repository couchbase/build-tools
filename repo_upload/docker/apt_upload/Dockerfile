# Docker container repo_upload program on Ubuntu 16.04
#
# Contains the repo_upload program for handling the APT uploads to S3

FROM couchbasebuild/ubuntu-1604-python3.6-base:latest
LABEL maintainer="build-team@couchbase.com"

USER root
ENV EDITION enterprise

# Install Aptly
RUN apt-get update && \
    apt-get install -y wget && \
    echo "deb http://repo.aptly.info/ squeeze main" >> /etc/apt/sources.list && \
    wget -qO - https://www.aptly.info/pubkey.txt | apt-key add - && \
    apt-get update && \
    apt-get install -u aptly

# Checkout directory for build-tools repository
ARG BUILD_TOOLS_GITDIR=/var/tmp/build-tools

# Install repo_upload
COPY build/src /src
RUN cd /src && \
    pip3.6 install -r requirements.txt && \
    pip3.6 install .
COPY build/repo_upload_entrypoint.sh /usr/sbin/

ENTRYPOINT ["/usr/sbin/repo_upload_entrypoint.sh"]
