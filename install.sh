#!/bin/bash

set -euo pipefail

function rollback_on_fail() {
  local PROJECT=$1
  local HELM_DEPLOYMENT=$2
  local ROLLBACK_FROM_STATUS=$3
  helm_cmd="helm -n $PROJECT"
  if $helm_cmd list -a | grep -q ${HELM_DEPLOYMENT} ; then
    current_status=$( $helm_cmd status ${HELM_DEPLOYMENT} --output json | jq -r '.info.status' )
    if [[ "$current_status" =~ $ROLLBACK_FROM_STATUS ]] ; then
      echo "Previous helm deployment unsuccessul or not done"
      rollback_to=$( $helm_cmd history --output json ${HELM_DEPLOYMENT} \
        | jq -r 'map(select(.status == "superseded" or .status == "deployed" ).revision) | max' )
      if [[ "$rollback_to" != null ]] ; then
        echo "Rollback to last healthy version ${rollback_to}"
        $helm_cmd rollback --wait --timeout 3m1s ${HELM_DEPLOYMENT} ${rollback_to}
      else
        echo "No healthy version available, uninstalling"
        $helm_cmd delete --wait --timeout 3m1s ${HELM_DEPLOYMENT}
      fi
    fi
  fi
}

function installHelm {
  curl -sSL https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 -o helm-installer
  bash helm-installer --version v3.10.0
}

ENV=$1
S3_FOLDER_NAME=${GITHUB_RUN_ID}
RANDOM_NUMBER=$( cat /dev/urandom | tr -dc '0-9' | fold -w 16 | head -n 1 )

echo "Setting up kubectl and heml"
installHelm
mkdir -p ~/.kube
echo "$HEROKLES_KUBECONFIG_BASE64" | base64 -d > ~/.kube/config
chmod 400 ~/.kube/config

export HELM_DEPLOYMENT="${PROJECT}-${ENV}"

if [[ -f herokles/install.sh ]] ; then
  echo "Install custom deployment"
  source ./herokles/install.sh
fi
set -x
echo "Install Helm deployment"

rollback_on_fail ${PROJECT} ${HELM_DEPLOYMENT} pending
helm upgrade --install --wait --timeout ${HEROKLES_HELM_TIMEOUT:-3m1s} \
  -n ${PROJECT} \
  ${HELM_DEPLOYMENT} \
  ${HELM_DIRECTORY:-herokles/helm} \
  --set RANDOM_NUMBER=$RANDOM_NUMBER \
  --set ENV=$ENV \
  --set S3_FOLDER_NAME=$S3_FOLDER_NAME \
  --set BRANCH=$BRANCH \
  --set SHA=$SHA \
  --set PROJECT=$PROJECT ${EXTRA_HELM_PARAMS:-} || \
  {
    echo "Helm deploymet failed"
    rollback_on_fail ${PROJECT} ${HELM_DEPLOYMENT} failed
    exit 1
  }
