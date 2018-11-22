#!/bin/bash

# This is intended to be run the plugin's root directory. `ci/unit/docker-test.sh`
# Ensure you have Docker installed locally and set the ELASTIC_STACK_VERSION environment variable.
set -e

VERSION_URL="https://gist.githubusercontent.com/jsvd/12c60459ba0cc505dc56867561b41806/raw/b66fc0ecd7433349d583e81125adb5ef6a9d6a6f/versions.json"

if [ "$ELASTIC_STACK_VERSION" ]; then
    if [[ "$SNAPSHOT" = "true" ]]; then
      ELASTIC_STACK_RETRIEVED_VERSION=$(curl $VERSION_URL -s | jq '.snapshots."'"$ELASTIC_STACK_VERSION"'"')
      echo $ELASTIC_STACK_RETRIEVED_VERSION
    else
      ELASTIC_STACK_RETRIEVED_VERSION=$(curl $VERSION_URL -s | jq '.releases."'"$ELASTIC_STACK_VERSION"'"')
    fi
    if [[ "$ELASTIC_STACK_RETRIEVED_VERSION" != "null" ]]; then
      # remove starting and trailing double quotes
      ELASTIC_STACK_RETRIEVED_VERSION="${ELASTIC_STACK_RETRIEVED_VERSION%\"}"
      ELASTIC_STACK_RETRIEVED_VERSION="${ELASTIC_STACK_RETRIEVED_VERSION#\"}"
      echo "Translated $ELASTIC_STACK_VERSION to ${ELASTIC_STACK_RETRIEVED_VERSION}"
      export ELASTIC_STACK_VERSION=$ELASTIC_STACK_RETRIEVED_VERSION
    fi

    echo "Testing against version: $ELASTIC_STACK_VERSION"

    if [[ "$ELASTIC_STACK_VERSION" = *"-SNAPSHOT" ]]; then
        cd /tmp
        wget https://snapshots.elastic.co/docker/logstash-"$ELASTIC_STACK_VERSION".tar.gz
        tar xfvz logstash-"$ELASTIC_STACK_VERSION".tar.gz  repositories
        echo "Loading docker image: "
        cat repositories
        docker load < logstash-"$ELASTIC_STACK_VERSION".tar.gz
        rm logstash-"$ELASTIC_STACK_VERSION".tar.gz
        cd -
    fi

    if [ -f Gemfile.lock ]; then
        rm Gemfile.lock
    fi

    docker-compose -f ci/unit/docker-compose.yml down
    docker-compose -f ci/unit/docker-compose.yml build
    #docker-compose -f ci/unit/docker-compose.yml up --exit-code-from logstash --force-recreate
else
    echo "Please set the ELASTIC_STACK_VERSION environment variable"
    echo "For example: export ELASTIC_STACK_VERSION=6.2.4"
    exit 1
fi

