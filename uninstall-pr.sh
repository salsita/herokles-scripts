#!/bin/bash

set -euo pipefail

function installHelm {
  curl -sSL https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 -o helm-installer
  bash helm-installer --version v3.10.0
}

ENV=$1

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

echo "Deleting environment variables."
if [[ $ENV != pr-${PR_NUM} ]] ; then
  echo "This script is only meant for PR destruction."
  exit 1
fi
aws ssm delete-parameter --name /${PROJECT}/${ENV}

echo "Setting up kubectl and heml"
installHelm
mkdir -p ~/.kube
echo "$HEROKLES_KUBECONFIG_BASE64" | base64 -d > ~/.kube/config
chmod 400 ~/.kube/config

if [[ -f herokles/uninstall.sh ]] ; then
  echo "Uninstall custom deployment"
else
  echo "Uninstall Helm deployment"
  helm uninstall -n ${PROJECT} ${PROJECT}-${ENV} --wait --timeout ${HEROKLES_HELM_TIMEOUT:-3m1s}
fi
