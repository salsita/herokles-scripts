#!/bin/bash

set -euo pipefail

readonly DEPLOYMENT_TIME=$( date +%s )
readonly NODE_VERSION=$( jq -r .engines.node package.json )
readonly DEPLOY_SCRIPT_VERSION=$( cat herokles/scripts_version )
readonly HELM_DEPLOYMENT="${PROJECT}-${ENV}"

function rollback_on_fail() {
  local ROLLBACK_FROM_STATUS=$1
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

function installHelm() {
  curl -sSL https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 -o helm-installer
  bash helm-installer --version v3.12.2
}

function main() {
  if [[ ! -d ~/.aws ]] ; then
    echo "Configuring aws cli."
    mkdir -p ~/.aws
    cat > ~/.aws/config <<eoco
[herokles]
region = $HEROKLES_AWS_REGION
eoco

    cat > ~/.aws/credentials <<eocre
[herokles]
aws_access_key_id = $HEROKLES_AWS_ACCESS_KEY_ID
aws_secret_access_key = $HEROKLES_AWS_SECRET_ACCESS_KEY
region = $HEROKLES_AWS_REGION
eocre
  fi

  echo "Getting environment variables."
  local JSON_FULL=$( aws --profile herokles ssm get-parameters --name /${PROJECT}/${ENV} )
  if [[ ! -z $( echo "$JSON_FULL" | jq -r '.InvalidParameters | .[]' ) ]] ; then
    echo "Missing environment variables paramater ${PROJECT}-${ENV}"
    exit 1
  fi

  echo "secrets:" > herokles/helm/values-envs.yaml
  local JSON=$( echo "$JSON_FULL" | jq -r '.Parameters | .[] | .Value' )
  local key val
  for key in $( echo "$JSON" | jq -r 'keys[]' ) ; do
    val=$( echo "$JSON" | jq -r .$key )
    if [[ $val == true ]] || [[ $val == false ]] || [[ $val =~ ^[0-9]+$ ]] ; then
      val=\"$val\"
    fi
    echo "  ${key}: ${val}" >> herokles/helm/values-envs.yaml
  done

  if [[ ! -d ~/.kube ]] && [[ -z ${KUBECONFIG:-} ]] ; then
    echo "Setting up kubectl and heml"
    installHelm
    mkdir -p ~/.kube
    echo "$HEROKLES_KUBECONFIG_BASE64" | base64 -d > ~/.kube/config
    chmod 400 ~/.kube/config
  fi

  if [[ -f herokles/install.sh ]] ; then
    echo "Install custom deployment"
    source ./herokles/install.sh
  fi

  echo "Install Helm deployment"
  rollback_on_fail pending
  helm upgrade --install --wait --timeout ${HEROKLES_HELM_TIMEOUT:-3m1s} \
    -n ${PROJECT} \
    ${HELM_DEPLOYMENT} \
    ${HELM_DIRECTORY:-herokles/helm} \
    -f herokles/helm/values-envs.yaml \
    --set DEPLOYMENT_TIME=$DEPLOYMENT_TIME \
    --set DEPLOY_SCRIPT_VERSION=$DEPLOY_SCRIPT_VERSION \
    --set ENV=$ENV \
    --set BRANCH=$BRANCH \
    --set SHA=$SHA \
    --set PROJECT=$PROJECT \
    --set HEROKLES_AWS_S3_BUILDS_BUCKET_FOLDER=$HEROKLES_AWS_S3_BUILDS_BUCKET_FOLDER \
    --set BASE_VERSION=$BASE_VERSION \
    --set LANG_VERSION=$NODE_VERSION \
    || {
      echo "Helm deploymet failed"
      rollback_on_fail failed
      exit 1
    }
}
main "$@"
