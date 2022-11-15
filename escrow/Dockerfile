FROM ubuntu:20.04
# Placeholder - this is overriden by escrow_config when a build is triggered using go.sh
ARG DOCKER_VERSION=20.10.5

RUN apt update && DEBIAN_FRONTEND=noninteractive apt install -y cmake curl git python

RUN set -x \
    && curl --fail https://storage.googleapis.com/git-repo-downloads/repo -o /usr/local/bin/repo \
    && chmod a+x /usr/local/bin/repo

RUN curl -Lo /tmp/docker.tgz https://download.docker.com/linux/static/stable/$(uname -m)/docker-$DOCKER_VERSION.tgz \
    && cd /tmp \
    && tar -zxvf docker.tgz \
    && chmod +x docker/* \
    && mv docker/* /usr/bin \
    && rm -rf /tmp/docker*

RUN useradd -ms /bin/bash couchbase
RUN mkdir -p /home/couchbase/.ssh && ssh-keyscan github.com >> /home/couchbase/.ssh/known_hosts
RUN apt install -y python3 python3-pip && pip3 install pyyaml

COPY . /app
RUN chmod +x /app/build_escrow.sh
RUN chmod +x /app/entrypoint.sh

WORKDIR /app
CMD ["bash", "/app/entrypoint.sh"]
