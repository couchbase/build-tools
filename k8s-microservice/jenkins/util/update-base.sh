#!/bin/bash -e

DOCKERFILE=$1

upstream_images=()
aliases=()

# Get list of images and their aliases
while read line; do
    if $(echo $line | grep -q "^FROM"); then
        upstream_images+=($(echo $line | awk '{print $2}'))
        if $(echo $line | grep -q " as "); then
            aliases+=($(echo $line | sed "s/.* as //"))
        fi
    fi
done < $DOCKERFILE

# Pull all non-alias images listed in FROM instructions
for image in "${upstream_images[@]}"; do
    if [[ ! "${aliases[@]}" =~ "${image}" ]]; then
        if [ "${image}" = "scratch" ]; then
            echo "Not updating 'scratch' base image"
        else
            echo "Updating base image ${image}"
            docker pull ${image}
        fi
    fi
done
