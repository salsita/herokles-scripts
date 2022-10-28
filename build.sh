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
JSON_TEMPLATE=
JSON_FULL=$( aws ssm get-parameters --name /${PROJECT}/${ENV} )

if [[ $ENV == pr-${PR_NUM:-''} ]] ; then
  JSON_TEMPLATE=$( aws ssm get-parameters --name /${PROJECT}/prs ) # get all template envs
  if [[ ! -z $( echo "$JSON_TEMPLATE" | jq -r '.InvalidParameters | .[]' ) ]] ; then
    echo "Template PR variables /${PROJECT}/prs not found."
    exit 1
  fi
  if [[ ! -z $( echo "$JSON_FULL" | jq -r '.InvalidParameters | .[]' ) ]] ; then # check if it's a new PR
    JSON=$( echo "$JSON_TEMPLATE" | jq -r '.Parameters | .[] | .Value' )
    if [[ -f herokles/set-custom-pr-envs.sh ]] ; then
      source ./herokles/set-custom-pr-envs.sh
    fi
    JSON=$( echo "$JSON" | jq -c ) # save as much space as possible
    aws ssm put-parameter --type String --name /${PROJECT}/${ENV} --value "$JSON"
  else # try to find new envs in /PROJECT/prs template, fill them in and push
    update=false
    JSON_TEMPLATE=$( echo "$JSON_TEMPLATE" | jq -r '.Parameters | .[] | .Value' )
    for key in $( echo "$JSON_TEMPLATE" | jq -r 'keys[]' ) ; do
      if [[ $( echo "$JSON" | jq -r .$key ) == null ]] ; then
        update=true
        JSON=$( echo "$JSON" | jq ".${key}=\"$( echo "$JSON_TEMPLATE" | jq -r .$key )\"" )
      fi
    done
    if [[ $update == true ]] ; then
      JSON=$( echo "$JSON" | jq -c ) # save as much space as possible
      aws ssm put-parameter --type String --name /${PROJECT}/${ENV} --value "$JSON"
    fi
  fi
else
  if [[ ! -z $( echo "$JSON_FULL" | jq -r '.InvalidParameters | .[]' ) ]] ; then
    echo "Environment variables for /${PROJECT}/${ENV} not found."
    exit 1
  else
    JSON=$( echo "$JSON_FULL" | jq -r '.Parameters | .[] | .Value' )
  fi
fi

for key in $( echo "$JSON" | jq -r 'keys[]' ) ; do
  export $key="$( echo "$JSON" | jq -r .$key )"
done

installToolCmd=
buildToolCmd=

if [[ -f yarn.lock ]] ; then
  echo "Using Yarn."
  installToolCmd="yarn --immutable"
  buildToolCmd=yarn
else
  echo "Using NPM."
  installToolCmd="npm ci"
  buildToolCmd="npm run"
fi

echo "Running $installToolCmd."
NODE_ENV=development $installToolCmd

if jq -e '.scripts."herokles:build"' package.json >/dev/null ; then
  echo "Running $buildToolCmd herokles:build."
  $buildToolCmd herokles:build
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
