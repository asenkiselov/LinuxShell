#!/bin/bash

### helper functions

# uncomment for debugging (prints every statement)
# set -o xtrace

serviceUpdate() {
  if [ $# -lt 2 ]; then
    echo "Missing parameters"
    exit 1
  fi

  DOCKER_STACK=$1
  SERVICE=$2
  IMAGE=$3

  if [ -z $3 ]; then
    IMAGE=latest   # default value
  fi

  CLEAN_DOCKER_STACK=${DOCKER_STACK//[^a-zA-Z0-9_-]/}
  CLEAN_SERVICE=${SERVICE//[^a-zA-Z0-9_-]/}
  CLEAN_IMAGE=${IMAGE//[^a-zA-Z0-9_-]/}

  echo "Deploying ${CLEAN_SERVICE} inside ${CLEAN_DOCKER_STACK}"

  IMAGE_FROM_COMPOSE=$(/usr/bin/docker service inspect ${CLEAN_DOCKER_STACK}_${SERVICE} --format '{{index .Spec.Labels "com.docker.stack.image"}}' | sed "s/latest/${CLEAN_IMAGE}/g")

  # update image from repo
  /usr/bin/docker pull $IMAGE_FROM_COMPOSE || exit 1

  IMAGE_WITH_REPODIGESTS=$(/usr/bin/docker inspect --type image --format '{{index .RepoDigests 0}}' ${IMAGE_FROM_COMPOSE})

  echo "Updating service ${CLEAN_SERVICE} inside ${CLEAN_DOCKER_STACK} with image ${IMAGE_WITH_REPODIGESTS}"

  # update service and fail the pipeline in case of error
  /usr/bin/docker service update --image $IMAGE_WITH_REPODIGESTS \
    --force --update-order start-first --with-registry-auth \
    --container-label-add last_deployed=$(date -u +%Y-%m-%dT%H:%M:%S) \
    ${CLEAN_DOCKER_STACK}_${CLEAN_SERVICE} || exit 1

  # print service status
  /usr/bin/docker service ps -f desired-state=Running --no-trunc ${CLEAN_DOCKER_STACK}_${CLEAN_SERVICE} | tail -n +2 || exit 1
}

serviceInspect() {

  if [ $# -lt 3 ]; then
    echo "Missing parameters"
    exit 1
  fi

  DOCKER_STACK=$1
  SERVICE=$2
  INSPECT_FILTER=$3


  CLEAN_DOCKER_STACK=${DOCKER_STACK//[^a-zA-Z0-9_-]/}
  CLEAN_SERVICE=${SERVICE//[^a-zA-Z0-9_-]/}

  
   # Check if service Running
  if /usr/bin/docker service ps -f desired-state=Running --no-trunc ${CLEAN_DOCKER_STACK}_${CLEAN_SERVICE} > /dev/null 2>&1;
  then

    /usr/bin/docker service inspect -f="$INSPECT_FILTER" ${CLEAN_DOCKER_STACK}_${CLEAN_SERVICE}

  else
    echo "ERROR: No such running service: ${CLEAN_DOCKER_STACK}_${CLEAN_SERVICE}"
  fi
}

stackDeploy() {
  if [ $# -lt 1 ]; then
    echo "Missing parameters"
    exit 1
  fi

  DOCKER_STACK=$1
  CLEAN_DOCKER_STACK=${DOCKER_STACK//[^a-zA-Z0-9_-]/}
  DOCKER_STACK_FILENAME=${CLEAN_DOCKER_STACK#nra_}

  echo "Check required files are present... Working directory is ${WORKDIR}."
  if [ ! -f ${WORKDIR}/docker-compose-${DOCKER_STACK_FILENAME}.yml ] || [ ! -f /root/.env ] ; then
    echo "Required files not found!"
    exit 1
  fi

  source /root/.env
  export $(grep "\S" /root/.env | grep -v "#" | cut -d= -f1) # export variables from file ignoring comments and blank lines
  if [ -f ${WORKDIR}/scripts/init.sh ] ; then
    echo "Found init script. Executing..."
    ${WORKDIR}/scripts/init.sh
  fi

  /usr/bin/docker stack deploy ${CLEAN_DOCKER_STACK} \
    --compose-file $WORKDIR/docker-compose-${DOCKER_STACK_FILENAME}.yml --with-registry-auth || exit 144
}

gitPull() {
  export GIT_SSL_NO_VERIFY=true
  cd $WORKDIR && /usr/bin/git pull
}

### main

TASK=$1
WEBHOOK_WORKDIR=$(dirname $(readlink -f "$0"))
# As we are using submodules and this script is going to run in the ./webhooks directory of the project,
# we need to move to the parent directory.
WORKDIR=$(dirname $WEBHOOK_WORKDIR)

case $TASK in
    deploy)
    serviceUpdate $2 $3 $4
    ;;
    check)
    stackDeploy $2
    ;;
    updaterepo)
    gitPull
    ;;
    inspect)
    # quotes are important because filters contain whitespaces
    serviceInspect $2 $3 "$4"
    ;;
    *)
    echo -e "The available options are create, deploy and update."
    echo -e "- deploy <stack> <service> <imagetag> - redeploy a service that has changes (e.g. new image)."
    echo -e "- check <stack> - apply the latest YAML config to the stack."
    echo -e "- updaterepo - refresh repo."
    echo -e "- inspect <stack> <service> <filter> - inspect a service by given filter"
    echo -e "Example usage: $(basename "$0") check nra_es"
    ;;
esac
