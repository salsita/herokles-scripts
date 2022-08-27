#!/bin/bash

set -euo pipefail

clean_modules() {
  depth=1
  while true ; do
    toDel=$( find . -maxdepth $depth -type d -name node_modules )
    if [[ "$toDel" == '' ]] ; then return 0 ; fi
    rm -rf $toDel
    depth=$(( depth + 1 ))
  done
}

ENV=$1

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

JSON="$( aws ssm get-parameters --name ${PROJECT}-${ENV} | jq -r '.Parameters | .[] | .Value' )"
for key in $( echo "$JSON" | jq -r 'keys[]' ) ; do
  export $key="$( echo "$JSON" | jq -r .$key )"
done

installCmd=
buildToolCmd=

if [[ -f yarn.lock ]] ; then
  installCmd="yarn --frozen-lockfile"
  buildToolCmd=yarn
else
  installCmd="npm ci"
  buildToolCmd="npm run"
fi

if jq -e '.scripts."herokles:preinstall"' package.json >/dev/null ; then
  $buildToolCmd herokles:preinstall
fi

$installCmd

if jq -e '.scripts."herokles:build"' package.json >/dev/null ; then
  $buildToolCmd herokles:build
fi

if jq -e '.scripts."herokles:postbuild"' package.json >/dev/null ; then
  $buildToolCmd herokles:postbuild
fi

if jq -e '.scripts."herokles:prodinstall"' package.json >/dev/null ; then
  clean_modules
  $buildToolCmd herokles:prodinstall
fi

if jq -e '.scripts."herokles:pack"' package.json >/dev/null ; then
  $buildToolCmd herokles:pack
else
  zip -r product.zip .
fi

aws s3 cp product.zip s3://${BUILD_AWS_S3_BUCKET}/${GITHUB_RUN_ID}/
