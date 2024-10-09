ARG JDK_VERSION
FROM eclipse-temurin:${JDK_VERSION}-jdk

ARG GERRIT_MAJOR_VERSION
ARG GERRIT_MINOR_VERSION
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
RUN build-plugin uploadvalidator
RUN build-plugin webhooks

# Community plugins
RUN build-plugin checks
RUN build-plugin checks-jenkins
RUN build-plugin events-log
RUN build-plugin oauth
RUN build-plugin readonly
RUN build-plugin reviewers
RUN build-plugin admin-console

ENTRYPOINT ["bash"]
