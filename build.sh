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

ENV=$1
S3_FOLDER_NAME=${GITHUB_RUN_ID}

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
  if [[ $ENV == pr-${PR_NUM:-''} ]] ; then
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
NODE_ENV=development $installCmd

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
  echo "Packing the code."
  tar czf product.tgz .
fi

echo "Uploading build to S3."
aws s3 cp product.tgz s3://${HEROKLES_AWS_S3_BUILDS_BUCKET}/${S3_FOLDER_NAME}/ >/dev/null
