FROM python:3.9-buster

ENV repo_release=v1.13.9.2

ENV git_user_name="Couchbase Build Team"
ENV git_user_email="build-team@couchbase.com"

RUN set -x \
    && groupadd -g 1000 couchbase \
    && useradd couchbase -g couchbase -m -s /bin/bash

RUN set -x \
    && apt-get update \
    && apt-get install -y gosu \
    && apt-get clean

RUN cd /tmp \
    && git clone https://gerrit.googlesource.com/git-repo \
    && cd git-repo \
    && git checkout ${repo_release} \
    && mv repo /usr/bin \
    && chmod +x /usr/bin/repo \
    && rm -rf /tmp/git-repo

RUN mkdir /root/.ssh
RUN ssh-keyscan github.com > /root/.ssh/known_hosts

WORKDIR /app

COPY requirements.txt setup.py __init__.py /app/
COPY manifest_tools /app/manifest_tools/

RUN python -m pip install -U pip
RUN python setup.py install

COPY jenkins /app/jenkins/
COPY entrypoint.sh /app/

RUN chmod +x /app/entrypoint.sh

ENTRYPOINT ["/app/entrypoint.sh"]
