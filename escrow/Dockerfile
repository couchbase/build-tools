FROM ubuntu:16.04
# Placeholder - this is overriden by escrow_config when a build is triggered using go.sh
ARG DOCKER_VERSION=19.03.5

RUN apt update && apt install -y curl git repo cmake
RUN curl -Lo /tmp/docker.tgz https://download.docker.com/linux/static/stable/x86_64/docker-$DOCKER_VERSION.tgz \
    && cd /tmp \
    && tar -zxvf docker.tgz \
    && chmod +x docker/* \
    && mv docker/* /usr/bin \
    && rm -rf /tmp/docker*

RUN useradd -ms /bin/bash couchbase
RUN mkdir -p /home/couchbase/.ssh && ssh-keyscan github.com >> /home/couchbase/.ssh/known_hosts

COPY . /app
RUN chmod +x /app/build_escrow.sh
RUN chmod +x /app/entrypoint.sh

WORKDIR /app
CMD ["bash", "/app/entrypoint.sh"]
