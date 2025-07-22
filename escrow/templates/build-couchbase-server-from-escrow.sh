#!/bin/bash
set -e

# Build Couchbase Server from escrow using linux-single Docker image
# Supports both x86_64 and aarch64 architectures

usage() {
  echo "Usage: $0 [<host_path>]"
  echo "args:"
  echo "  host_path - path to the volume this script resides in (required only if script is being run in a container)"
  exit 1
}

export HOST_VOLUME_PATH=$1

container_workdir=/home/couchbase

# Ensure docker is present
docker version > /dev/null 2>&1
if [ $? -ne 0 ]
then
  echo "Docker must be installed and usable by the current user to build from escrow"
  exit 5
fi

# We need to make sure the user inside the container can
# access the docker socket for interacting with the sidecar
# containers, to accomplish this, we get the docker gid on
# the host up front, create the docker group in the container
# at startup (if missing), and then add the couchbase user
# (if missing)
if [[ "$OSTYPE" == "darwin"* ]]; then
  # macOS
  dockergroup=$(dscl . -read /Groups/docker PrimaryGroupID 2>/dev/null | awk '{print $2}' || echo "999")
else
  # Linux
  dockergroup=$(getent group docker | cut -d: -f3)
fi

if [ "$HOST_VOLUME_PATH" = "" ]
then
  # If this script is running inside a container, we need
  # to know the host path to the directory it lives in
  # or move it out to a VM
  if [ -f "/.dockerenv" ]; then
    echo "Please run this script on bare metal/VM or provide an additional arg with the absolute *host* path to the directory containing the escrow deposit"
    exit 1
  else
    MOUNT="-v $(pwd):/home/couchbase/escrow"
  fi
else
  MOUNT="-v ${HOST_VOLUME_PATH}:/home/couchbase/escrow"
fi

heading() {
  echo
  echo ::::::::::::::::::::::::::::::::::::::::::::::::::::
  echo $*
  echo ::::::::::::::::::::::::::::::::::::::::::::::::::::
  echo
}

ROOT=`pwd`

# Load Docker worker image
cd docker_images

# Use linux-single image for both x86_64 and aarch64
echo "Using linux-single Docker image for architecture $(uname -m)"
IMAGE=couchbasebuild/$( basename -s .tar.gz $( ls server-linux* | head -1 ) )
if [[ -z "`docker images -q ${IMAGE}`" ]]
then
  heading "Loading Docker image ${IMAGE}..."
  gzip -dc server-linux* | docker load
fi

# Run Docker worker
WORKER="linux-worker"
cd ${ROOT}

set +e
docker inspect ${WORKER} > /dev/null 2>&1
if [ $? -ne 0 ]
then
  set -e
  heading "Starting Docker worker container..."

  # We specify external DNS (Google's) to ensure we don't find
  # things on our LAN. We also point packages.couchbase.com to
  # a bogus IP to ensure we aren't dependent on existing packages.
  docker run --name "${WORKER}" -d \
    --add-host packages.couchbase.com:8.8.8.8 \
    --dns 8.8.8.8 \
    ${MOUNT} \
    -v /var/run/docker.sock:/var/run/docker.sock:rw \
    -v serverbuild_optcouchbase:/opt/couchbase \
    "${IMAGE}" bash -c "set -x \
       && (cat /etc/group | grep docker || groupadd -g ${dockergroup} docker) \
       && (groups couchbase | grep docker || usermod -aG docker couchbase) \
       && tail -f /dev/null"
else
  docker start "${WORKER}"
fi
set -e

# Load local copy of escrowed source code into container
# Removed -t from docker exec command as Jenkins doesn't like it: the input
# device is not a TTY
if [[ ! -z ${WORKSPACE} ]]
then
  DOCKER_EXEC_OPTION='-i'
else
  DOCKER_EXEC_OPTION='-it'
fi

DOCKER_EXEC_OPTION="${DOCKER_EXEC_OPTION} -ucouchbase"

docker exec ${DOCKER_EXEC_OPTION} ${WORKER} mkdir -p ${container_workdir}/escrow
docker exec ${WORKER} rm -f ./src/godeps/src/github.com/google/flatbuffers/docs/source/CONTRIBUTING.md

heading "Copying escrowed dependencies into container"
docker cp ./.cbdepscache ${WORKER}:${container_workdir}
docker cp ./deps ${WORKER}:${container_workdir}

# Fix ownership of copied directories and files
docker exec ${WORKER} chown -R couchbase:couchbase ${container_workdir}/.cbdepscache ${container_workdir}/deps ${container_workdir}/escrow/in-container-build.sh ${container_workdir}/escrow/escrow_config

# Launch build process
heading "Running full Couchbase Server build in container..."
echo "docker exec ${DOCKER_EXEC_OPTION} ${WORKER} bash \
  ${container_workdir}/escrow/in-container-build.sh ${container_workdir} linux @@VERSION@@"
docker exec ${DOCKER_EXEC_OPTION} ${WORKER} bash \
  ${container_workdir}/escrow/in-container-build.sh ${container_workdir} linux @@VERSION@@

# And copy the installation packages out of the container.
heading "Copying installer binaries"

cd ${ROOT}

for file in src/*linux*; do
  ls $file
  filename=`basename ${file}`
  mv ${file} ../${basename/-9999/}
done
rm -rf src/*.deb src/*.rpm *.tar.gz

docker rm -f "${WORKER}"
