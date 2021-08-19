# Docker container for check_builds program on Ubuntu 16.04
#
# Contains the following:
#  - cbbuild package from python-couchbase-commons
#  - check_build programs

FROM couchbasebuild/ubuntu-1604-python3.6-base:latest
LABEL maintainer="build-team@couchbase.com"

USER root

# Install software in build_database directory
COPY . /src
RUN cd /src && \
    pip3.6 install -r requirements.txt && \
    pip3.6 install .

CMD ["check_builds", "-c", "/etc/check_builds.ini"]
