#!/bin/bash

###########
# Functions
###########

# Logging helpers
function info (){
  local MESSAGE=$1
  local PREFIX=${2:-"INFO"}
  echo -e "\n \e[1m ${PREFIX}: ${MESSAGE} \e[0m" >&2
}
function warn (){
  local MESSAGE=$1
  local PREFIX=${2:-"WARN"}
  echo -e "\n \e[1;33m ${PREFIX}: ${MESSAGE} \e[0m" >&2
}
function error (){
  local MESSAGE=$1
  local PREFIX=${2:-"ERROR"}
  echo -e "\n \e[1;31m ${PREFIX}: ${MESSAGE} \e[0m" >&2
}

# Skip project if it does not match provided GROUP and PROJECT
function skipProject() {
  CURRENT_PROJECT=$1
  CURRENT_GROUP=$2
  
  if [[ -z "$GROUP" ]]; then
    # do not skip if no GROUP is set
    return 1 # false
  elif [[ "$GROUP" != "$CURRENT_GROUP" ]]; then
    # skip if a GROUP is set and does not match current group
    return 0 # true
  fi

  if [[ -z "$PROJECT" ]]; then
    # do not skip if no PROJECT is set
    return 1 # false
  else
    STRIPPED_CURRENT_PROJECT=$(echo $CURRENT_PROJECT | cut -d':' -f1)
    if echo ",$PROJECT," | grep -q ",$STRIPPED_CURRENT_PROJECT,"; then  
      # do not skip if PROJECT contains current project
      return 1 # false
    else 
      # oterwise skip
      return 0 # true
    fi  
  fi

}
