# Docker container for repo_upload program on CentOS 7.4
#
# Contains the repo_upload program for handling the Yum uploads to S3

FROM centos:7.4.1708
LABEL maintainer="build-team@couchbase.com"

USER root
ENV EDITION=enterprise

# Install some prerequisites and additional needed software
RUN yum install --setopt=keepcache=0 -y \
        createrepo \
        curl \
        deltarpm \
        git \
        rpm-sign \
        tar \
        yum-utils

# Create couchbase user
RUN groupadd -g 1000 couchbase && \
    useradd couchbase -g couchbase -u 1000 -G wheel -m -s /bin/bash && \
    echo 'couchbase:couchbase' | chpasswd

# Python 3.9.6 (using miniforge)
ARG MINIFORGE_VER=4.10.3-5
RUN set -x && \
      curl -Lo /tmp/miniforge.sh \
        https://github.com/conda-forge/miniforge/releases/download/${MINIFORGE_VER}/Miniforge3-${MINIFORGE_VER}-Linux-x86_64.sh && \
      sh /tmp/miniforge.sh -b -f -p /usr/local/miniforge && \
      rm /tmp/miniforge.sh
RUN for exe in python python3 pip pip3; do ln -s /usr/local/miniforge/bin/${exe} /usr/local/bin/${exe}; done

# Update locale
RUN localedef -i en_US -f UTF-8 en_US.UTF-8
ENV LANG=en_US.UTF-8

# Install repo_upload
COPY build/src /src
RUN cd /src && \
    pip3 install -r requirements.txt && \
    pip3 install .
# One downside to using miniforge - the bin/ directory isn't /usr/local/bin
RUN ln -s /usr/local/miniforge/bin/repo_upload /usr/local/bin

COPY build/repo_upload_entrypoint.sh /usr/sbin/

ENTRYPOINT ["/usr/sbin/repo_upload_entrypoint.sh"]
