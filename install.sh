#!/bin/bash

set -euo pipefail

readonly DEPLOYMENT_TIME=$( date +%s )
readonly NODE_VERSION=$( jq -r .engines.node package.json )
readonly BASE_VERSION=$( cat herokles/base_version )
readonly DEPLOY_SCRIPT_VERSION=$( cat herokles/scripts_version )
readonly HELM_DEPLOYMENT="${PROJECT}-${ENV}"

function rollback_on_fail() {
  local rollback_from_status=$1
  helm_cmd="helm -n $PROJECT"
  if $helm_cmd list -a | sed 1d | awk '{ print $1 }' | grep -q ^${HELM_DEPLOYMENT}$ ; then
    current_status=$( $helm_cmd status ${HELM_DEPLOYMENT} --output json | jq -r '.info.status' )
    if [[ "$current_status" =~ $rollback_from_status ]] ; then
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

function set_aws_creds() {
  echo "Configuring aws cli."
  local creds=(
    "[herokles]"
    "aws_access_key_id = $HEROKLES_AWS_ACCESS_KEY_ID"
    "aws_secret_access_key = $HEROKLES_AWS_SECRET_ACCESS_KEY"
    "region = $HEROKLES_AWS_REGION"
  )
  mkdir ~/.aws
  printf '%s\n' "${creds[@]}" > ~/.aws/credentials
}

function installHelm() {
  curl -sSL https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 -o helm-installer
  bash helm-installer --version v3.12.2
}

function main() {
  [[ -d ~/.aws ]] || set_aws_creds

  echo "Getting environment variables."
  local json_full=$( aws --profile herokles ssm get-parameters --name /${PROJECT}/${ENV} )
  if [[ ! -z $( echo "$json_full" | jq -r '.InvalidParameters | .[]' ) ]] ; then
    echo "Missing environment variables paramater ${PROJECT}-${ENV}"
    exit 1
  fi

  echo "secrets:" > herokles/helm/values-envs.yaml
  local json=$( echo "$json_full" | jq -r '.Parameters | .[] | .Value' )
  echo "$json" | jq . >/dev/null || {
    echo "Formatting error in AWS Parameter store environment variables."
    exit 1
  }
  local key val
  for key in $( echo "$json" | jq -r 'keys[]' ) ; do
    val=$( echo "$json" | jq .$key )
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
    --set HEROKLES_AWS_REGION=$HEROKLES_AWS_REGION \
    --set HEROKLES_AWS_S3_BUILDS_BUCKET=$HEROKLES_AWS_S3_BUILDS_BUCKET \
    --set HEROKLES_AWS_S3_BUILDS_FOLDER=$HEROKLES_AWS_S3_BUILDS_FOLDER \
    --set BASE_VERSION=$BASE_VERSION \
    --set LANG_VERSION=$NODE_VERSION \
    || {
      echo "Helm deploymet failed"
      rollback_on_fail failed
      exit 1
    }
}
main "$@"
