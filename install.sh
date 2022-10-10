#!/bin/bash

set -euo pipefail

clean_modules() {
  depth=1
  while true ; do
    toDel=$( find . -maxdepth $depth -type d -name node_modules )
    echo $toDel
    if [[ "$toDel" == '' ]] ; then return 0 ; fi
    rm -rf $toDel
    depth=$(( depth + 1 ))
  done
}

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
S3_FOLDER_NAME=${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}

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
JSON=
JSON_FULL=$( aws ssm get-parameters --name /${PROJECT}/${ENV} )

if [[ ! -z $( echo "$JSON_FULL" | jq -r '.InvalidParameters | .[]' ) ]] ; then
  if [[ $ENV == pr-${PR_NUM} ]] ; then
    echo "New PR deployment, copying env vars from the template."
    JSON=$( aws ssm get-parameters --name /${PROJECT}/prs | jq -r '.Parameters | .[] | .Value' )
    if [[ -f herokles/set-custom-pr-envs.sh ]] ; then
      source ./herokles/set-custom-pr-envs.sh
    fi
    aws ssm put-parameter --type String --name /${PROJECT}/${ENV} --value "$JSON"
  else
    echo "Environment variables for /${PROJECT}/${ENV} not found."
    exit 1
  fi
else
  JSON=$( echo "$JSON_FULL" | jq -r '.Parameters | .[] | .Value' )
fi

for key in $( echo "$JSON" | jq -r 'keys[]' ) ; do
  export $key="$( echo "$JSON" | jq -r .$key )"
done

installCmd=
buildToolCmd=

if [[ -f yarn.lock ]] ; then
  echo "Using Yarn."
  installCmd="yarn --frozen-lockfile"
  buildToolCmd=yarn
else
  echo "Using NPM."
  installCmd="npm ci"
  buildToolCmd="npm run"
fi

if jq -e '.scripts."herokles:preinstall"' package.json >/dev/null ; then
  echo "Running $buildToolCmd herokles:preinstall."
  $buildToolCmd herokles:preinstall
fi

echo "Running $installCmd"
$installCmd

if jq -e '.scripts."herokles:build"' package.json >/dev/null ; then
  echo "Running $buildToolCmd herokles:build."
  $buildToolCmd herokles:build
fi

if jq -e '.scripts."herokles:postbuild"' package.json >/dev/null ; then
  echo "Running $buildToolCmd herokles:postbuild."
  $buildToolCmd herokles:postbuild
fi

if jq -e '.scripts."herokles:prodinstall"' package.json >/dev/null ; then
  echo "Cleaning up all node_modules and running $buildToolCmd herokles:prodinstall."
  clean_modules
  $buildToolCmd herokles:prodinstall
fi

if jq -e '.scripts."herokles:pack"' package.json >/dev/null ; then
  echo "Running $buildToolCmd herokles:pack."
  $buildToolCmd herokles:pack
else
  zip --symlinks -r product.zip .
fi

echo "Uploading build to S3."
aws s3 cp product.zip s3://${HEROKLES_AWS_S3_BUILDS_BUCKET}/${S3_FOLDER_NAME}/ >/dev/null

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
