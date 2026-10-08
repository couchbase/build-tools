ARG JDK_VERSION
FROM eclipse-temurin:${JDK_VERSION}-jdk

ARG GERRIT_MAJOR_VERSION
ARG GERRIT_MINOR_VERSION
ARG GERRIT_BRANCH
# ENV rather than ARG alone, so ad-hoc `docker run` builds resolve the same way
ENV GERRIT_MAJOR_VERSION=${GERRIT_MAJOR_VERSION}
ENV GERRIT_BRANCH=${GERRIT_BRANCH}
ENV PLUGIN_MINOR_VERSION=${GERRIT_MINOR_VERSION}

RUN set -x \
    && apt update && apt install -y \
        curl \
        gcc \
        g++ \
        git \
        python3 \
        tar \
        zip \
    && apt clean all

ENV NVM_DIR /usr/local/nvm
ENV NODE_VERSION 20.17.0

RUN mkdir $NVM_DIR \
    && curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.0/install.sh | bash \
    && . $NVM_DIR/nvm.sh \
    && nvm install $NODE_VERSION \
    && nvm alias default $NODE_VERSION \
    && nvm use default

ENV NODE_PATH $NVM_DIR/versions/node/v$NODE_VERSION/lib/node_modules
ENV PATH      $NVM_DIR/versions/node/v$NODE_VERSION/bin:$PATH

RUN npm install --global @bazel/bazelisk

#################
# Plugin builds #
#################
COPY build-plugin.sh /usr/local/bin/build-plugin

RUN set -x \
    && git clone https://gerrit.googlesource.com/gerrit

# Stock plugins
RUN build-plugin avatars-gravatar
RUN build-plugin codemirror-editor
RUN build-plugin commit-message-length-validator
RUN build-plugin delete-project
RUN build-plugin download-commands
RUN build-plugin hooks
RUN build-plugin plugin-manager
RUN build-plugin replication
RUN build-plugin reviewnotes
RUN build-plugin singleusergroup
# upstream BUILD hardcodes a second Gerrit-ApiVersion; copied per plugin so a
# patch change only invalidates layers from here on
COPY patches/uploadvalidator /patches/uploadvalidator
RUN build-plugin uploadvalidator
RUN build-plugin webhooks

# Community plugins
# master needs aspect_rules_* and a newer bazlets than 3.14 pins; a8e36ec is
# the last commit before that. Revisit if checks cuts a stable-3.14.
RUN PLUGIN_BRANCH=a8e36eca9ca3f1900d0a511c0f1ff6942f867ff8 build-plugin checks
RUN build-plugin checks-jenkins
RUN build-plugin events-log
RUN build-plugin oauth
RUN build-plugin readonly
# master needs aspect_rules_*; stable-3.13 differs only in formatting
RUN PLUGIN_BRANCH=stable-3.13 build-plugin reviewers
RUN build-plugin admin-console
RUN build-plugin rename-project

ENTRYPOINT ["bash"]
