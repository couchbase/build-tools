FROM python:3.8-slim

ARG GERRIT_MAJOR_VERSION=3
ENV GERRIT_MAJOR_VERSION=${GERRIT_MAJOR_VERSION}

RUN set -x \
    && apt update && apt install -y \
        curl \
        gcc \
        git \
        nodejs \
        npm \
        openjdk-11-jdk \
        zip \
    && apt clean \
    && npm install --global @bazel/bazelisk

#################
# Plugin builds #
#################
COPY build-plugin.sh /usr/local/bin/build-plugin

RUN set -x \
    && git clone https://gerrit.googlesource.com/gerrit

RUN build-plugin admin-console
RUN build-plugin oauth
RUN build-plugin readonly
RUN build-plugin reviewers
# At time of writing, avatars-gravatar's most current stable branch is 3.0
# which causes errors in newest version of gerrit. The SHA specified here
# is the current tip of master, which builds correctly against the gerrit
# 3.5 source tree
RUN PLUGIN_BRANCH=4d45f665974934ac827702c1e1da60f3a705a301 build-plugin avatars-gravatar
# None of checks' stable branches seem to build
RUN PLUGIN_BRANCH=2e3f9f291310b4f3822b4900c72a4e781d37c2bf build-plugin checks
# verify-status stable branches break gerrit upgrades
RUN PLUGIN_BRANCH=f85b180c3f5ce8ba527f89b28418de02ff7f0574 build-plugin verify-status
RUN build-plugin events-log

ENTRYPOINT ["bash"]
