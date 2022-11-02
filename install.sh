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
DEPLOYMENT_TIME=$( date +%s )
NODE_VERSION=$( jq -r .engines.node package.json )
DEPLOY_SCRIPT_VERSION=$(cat herokles/scripts_version)

echo "Configuring aws cli."
mkdir -p ~/.aws

cat > ~/.aws/config <<eoco
[default]
region = $HEROKLES_AWS_REGION
eoco

cat > ~/.aws/credentials <<eocre
[default]
aws_access_key_id = $HEROKLES_AWS_ACCESS_KEY_ID
aws_secret_access_key = $HEROKLES_AWS_SECRET_ACCESS_KEY
region = $HEROKLES_AWS_REGION
eocre

echo "Getting environment variables."
JSON_FULL=$( aws ssm get-parameters --name /${PROJECT}/${ENV} )
if [[ ! -z $( echo "$JSON_FULL" | jq -r '.InvalidParameters | .[]' ) ]] ; then
  echo "Missing environment variables paramater ${PROJECT}-${ENV}"
  exit 1
fi

echo "secrets:" > herokles/helm/values-envs.yaml
JSON=$( echo "$JSON_FULL" | jq -r '.Parameters | .[] | .Value' )
for key in $( echo "$JSON" | jq -r 'keys[]' ) ; do
  val=$( echo "$JSON" | jq -r .$key )
  if [[ $val == true ]] || [[ $val == false ]] || [[ $val =~ ^[0-9]+$ ]] ; then
    val=\"$val\"
  fi
  echo "  ${key}: ${val}" >> herokles/helm/values-envs.yaml
done

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

echo "Install Helm deployment"

rollback_on_fail ${PROJECT} ${HELM_DEPLOYMENT} pending
helm upgrade --install --wait --timeout ${HEROKLES_HELM_TIMEOUT:-3m1s} \
  -n ${PROJECT} \
  ${HELM_DEPLOYMENT} \
  ${HELM_DIRECTORY:-herokles/helm} \
  -f herokles/helm/values-envs.yaml \
  --set DEPLOYMENT_TIME=$DEPLOYMENT_TIME \
  --set DEPLOY_SCRIPT_VERSION=$DEPLOY_SCRIPT_VERSION \
  --set ENV=$ENV \
  --set S3_FOLDER_NAME=$S3_FOLDER_NAME \
  --set BRANCH=$BRANCH \
  --set SHA=$SHA \
  --set PROJECT=$PROJECT \
  --set NODE_VERSION=$NODE_VERSION || \
  {
    echo "Helm deploymet failed"
    rollback_on_fail ${PROJECT} ${HELM_DEPLOYMENT} failed
    exit 1
  }
