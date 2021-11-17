#!/bin/bash


#
# Script to verify application's image hash is tha same as the expected one (in the registry)
#

# Filter for image info in "docker service inspect" output
FILTER='{{json .Spec.TaskTemplate.ContainerSpec.Image}}'
# Load shared functions
source ./functions.sh

info "Loading default values"
source projects.env

ES_SWARM_MANAGER_HOSTNAME=
SOA_SWARM_MANAGER_HOSTNAME=
DOCKER_PULL_REGISTRY=

if [ -z "$NEXUS_USER" ] && [ -z "$NEXUS_PASS" ]; then
   # See GitLab CI/CD variables
   error "Need to set NEXUS_USER and NEXUS_PASS"
   exit 1
fi

if [ -z "$TOKEN_HOOK" ]; then
  # See GitLab CI/CD variables
  error "Need to set token TOKEN_HOOK to authenticate to WebHook"
  exit 1
fi

if [ ! -f $(command -v curl) ]; then
  error "No curl command found"
  exit 189
fi


# NOTE: This is a workaround due to the location of Base Admin Client.
# It is deployed as part of the SOA stack in Docker Swarm but its source code and image are part of the ES group.
# Therefore, when we sync Docker images we use it in the ES group but when we deploy individual images we use it in the SOA group.
function isEsBaseAdminClient() {

  local PARAM_PROJECT=$1
  local PARAM_GROUP=$2
  local REGEX_BASE_ADMIN_CLIENT="base-admin-client.*"

  if [[ $PARAM_GROUP == "es" && $PARAM_PROJECT =~ $REGEX_BASE_ADMIN_CLIENT ]];then
    return 0 # true
  else
    return 1 # false
  fi

}


function fetchImageHashFromDockerRegistry() {

  local SERVICE=$1
  local STACK=$2
  local VERSION=$3
  
  # add "-v" to curl to debug
  hashHeader=$(curl  -S --silent --head -H 'Accept:application/vnd.docker.distribution.manifest.v2+json' \
    -u ${NEXUS_USER}:${NEXUS_PASS} \
    http://${DOCKER_PULL_REGISTRY}:8081/repository/docker-prod/v2/nra-soa-prod/${STACK}-${SERVICE}/manifests/${VERSION} | grep "Docker-Content-Digest:")
  
  info "Docker Registry hash header: $hashHeader"  
  # command 'sed -e "s/\r//g"' is used to remove all carriage-return character at the end
  echo $hashHeader | cut -d ':' -f3 | sed -e "s/\r//g"

}

function inspectServiceImageHashFromDockerSwarm() {

  local SWARM_MANAGER_HOSTNAME=$1
  local SERVICE=$2
  local STACK=$3

  response=$(curl  -S --silent --location --request POST -k "https://${SWARM_MANAGER_HOSTNAME}:1551/hooks/inspect" \
    --header "X-Token:${TOKEN_HOOK}" \
    --header "Content-Type:application/json" \
    --data-raw "{\"stack\":\"nra_${STACK}\",\"service\":\"${SERVICE}\",\"filter\":\"${FILTER}\"}") 
  
  info "Docker Swarm $SWARM_MANAGER_HOSTNAME response: $response"

  echo $response | grep -o 'sha256.*' | cut -d ':' -f2  | sed 's/"//' 

}

function checkImageHashes() {

  local SWARM_MANAGER_HOSTNAME=$1
  local PROJECTS=$2
  local STACK=$3
  local RETURN_CODE=0
  
  if [[ "${STACK}" != "es" ]] && [[ "${STACK}" != "soa" ]]; then
    error "Unknown stack ${STACK}. Only 'es' and 'soa' are supported"
    return 1
  fi

  for CURRENT_PROJECT in $PROJECTS;
  do
    if skipProject $CURRENT_PROJECT $STACK; then
      warn "Skip checking project ${CURRENT_PROJECT} of group ${STACK}"
      continue
    fi
    
    APPLICATION=$(echo $CURRENT_PROJECT | cut -d':' -f1)
    VERSION=$(echo $CURRENT_PROJECT | cut -d':' -f2)
    
    EXPECTED_IMAGE_HASH=$(fetchImageHashFromDockerRegistry ${APPLICATION} ${STACK} ${VERSION})
    
    CURRENT_STACK=$STACK
    CURRENT_SWARM_MANAGER_HOSTNAME=$SWARM_MANAGER_HOSTNAME
    if isEsBaseAdminClient $APPLICATION $STACK; then
      warn "Switch $APPLICATION's group from '$STACK' to 'soa' & the target swarm to $SOA_DEPLOY_HOSTNAME"
      CURRENT_STACK="soa"
      CURRENT_SWARM_MANAGER_HOSTNAME=$SOA_SWARM_MANAGER_HOSTNAME
    fi

    ACTUAL_IMAGE_HASH=$(inspectServiceImageHashFromDockerSwarm ${CURRENT_SWARM_MANAGER_HOSTNAME} ${APPLICATION} ${CURRENT_STACK})

    if [[ "$EXPECTED_IMAGE_HASH" == "$ACTUAL_IMAGE_HASH" ]]; then
      info "$CURRENT_STACK-$APPLICATION: OK"
    else
      error "ERROR $CURRENT_STACK-$APPLICATION image hash does not match. Expected hash in Docker registry: ${EXPECTED_IMAGE_HASH}. Actual hash in Docker Swam ${CURRENT_SWARM_MANAGER_HOSTNAME}: ${ACTUAL_IMAGE_HASH}"
      RETURN_CODE=2
    fi
  done

  return $RETURN_CODE
}


######
# Main
######


warn "Compare SOA"
checkImageHashes $SOA_SWARM_MANAGER_HOSTNAME "${soaProjects}" "soa"
SOA_EXIT_CODE=$?

warn "Compare ES"
checkImageHashes $ES_SWARM_MANAGER_HOSTNAME "${esProjects}" "es"
ES_EXIT_CODE=$?

exit $((SOA_EXIT_CODE + ES_EXIT_CODE))
