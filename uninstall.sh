#!/bin/bash

set -euo pipefail

function installHelm() {
  curl -sSL https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 -o helm-installer
  bash helm-installer --version v3.12.2
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

function main() {
  [[ -d ~/.aws ]] || set_aws_creds

  echo "Deleting environment variables."
  if [[ ${FORCE_UNINSTALL:-} != true ]] && [[ $ENV != pr-${PR_NUM} ]] ; then
    echo "ENV has to be a PR or FORCE_UNINSTALL=true must be set."
    exit 1
  fi
  aws --profile herokles ssm delete-parameter --name /${PROJECT}/${ENV} || echo "Parameterer /${PROJECT}/${ENV} not found."

  if [[ ! -d ~/.kube ]] && [[ -z ${KUBECONFIG:-} ]] ; then
    echo "Setting up kubectl and heml"
    installHelm
    mkdir -p ~/.kube
    echo "$HEROKLES_KUBECONFIG_BASE64" | base64 -d > ~/.kube/config
    chmod 400 ~/.kube/config
  fi

  if [[ -f herokles/uninstall.sh ]] ; then
    echo "Uninstall custom deployment"
  else
    echo "Uninstall Helm deployment"
    helm uninstall -n ${PROJECT} ${PROJECT}-${ENV} --wait --timeout ${HEROKLES_HELM_TIMEOUT:-3m1s}
  fi
}

main "$@"
