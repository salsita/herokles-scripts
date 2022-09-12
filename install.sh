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

function installHelm {
  curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 -o helm-installer
  bash helm-installer --version v3.8.1
}

ENV=$1

echo "Configuring aws cli."
mkdir -p ~/.aws

cat > ~/.aws/config <<eoco
[default]
region = $BUILD_AWS_REGION
eoco

cat > ~/.aws/credentials <<eocre
[default]
aws_access_key_id = $BUILD_AWS_ACCESS_KEY_ID
aws_secret_access_key = $BUILD_AWS_SECRET_ACCESS_KEY
region = $BUILD_AWS_REGION
eocre

echo "Getting environment variables."
if [[ $ENV == prs ]] ; then
  export ENV=pr-${PR_NUM}
  # TODO copy into new env vars if missing, run custom scripts
fi
JSON="$( aws ssm get-parameters --name ${PROJECT}-${ENV} | jq -r '.Parameters | .[] | .Value' )"
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
  zip --symlinks --r product.zip .
fi

echo "Uploading build to S3."
aws s3 cp product.zip s3://${BUILD_AWS_S3_BUCKET}/${GITHUB_RUN_ID}/ >/dev/null

echo "Setting up kubectl and heml"
installHelm
mkdir -p ~/.kube
echo "$KUBECONFIG_BASE64" | base64 -d > ~/.kube/config

echo "Install Helm deployment"
helm upgrade --install --wait --timeout 15m1s \
  ${PROJECT}-${ENV} \
  herokles/helm \
  --set ENV=$ENV \
  --set GITHUB_RUN_ID=$GITHUB_RUN_ID
