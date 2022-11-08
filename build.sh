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
S3_FOLDER_NAME=${GITHUB_RUN_ID:-}

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
JSON=$( mktemp )
JSON_TEMPLATE=$( mktemp )
JSON_FULL=$( mktemp )
aws ssm get-parameters --name /${PROJECT}/${ENV} > $JSON_FULL

if [[ $ENV == pr-${PR_NUM:-''} ]] ; then
  aws ssm get-parameters --name /${PROJECT}/prs > $JSON_TEMPLATE # get all template envs
  if [[ ! -z $( jq -r '.InvalidParameters | .[]' $JSON_TEMPLATE ) ]] ; then
    echo "Template PR variables /${PROJECT}/prs not found."
    exit 1
  fi
  if [[ ! -z $( jq -r '.InvalidParameters | .[]' $JSON_FULL ) ]] ; then # check if it's a new PR
    echo "New PR - setting to copy from /${PROJECT}/prs."
    echo '{ "Parameters": [ { "Value": { } } ] }' > $JSON_FULL
  fi
  # find new envs in /PROJECT/prs template, fill them in and push
  # $update file works a) for retrieving only the env var values from a rich JSON and b) as a condition checker for when to update pr-<num> parameter
  update=$( mktemp )
  jq -r '.Parameters | .[] | .Value' $JSON_FULL > $update
  cat $update > $JSON
  jq -r '.Parameters | .[] | .Value' $JSON_TEMPLATE > $update
  cat $update > $JSON_TEMPLATE
  echo > $update
  for key in $( jq -r 'keys[]' $JSON_TEMPLATE ) ; do
    if [[ $( jq -r .$key $JSON ) == null ]] ; then
      cat $JSON | jq ".${key}=\"$( jq -r .$key $JSON_TEMPLATE )\"" > $update
      cat $update > $JSON
    fi
  done
  if [[ -f ./herokles/set-custom-pr-envs.sh ]] ; then
    ./herokles/set-custom-pr-envs.sh \
    | while read line ; do
      key=$( echo "$line" | cut -d'=' -f1 )
      val=$( echo "$line" | cut -d'=' -f2- )
      if [[ $( jq -r .$key $JSON ) == null ]] ; then
        cat $JSON | jq ".${key}=\"${val}\"" > $update
        cat $update > $JSON
      fi
    done
  fi
  if [[ ! -z $( cat $update ) ]] ; then
    echo "Uploading new environment variables."
    aws ssm put-parameter --type String --name /${PROJECT}/${ENV} --overwrite --value "$( jq -c . $JSON )"
  fi
else
  if [[ ! -z $( jq -r '.InvalidParameters | .[]' $JSON_FULL ) ]] ; then
    echo "Environment variables for /${PROJECT}/${ENV} not found."
    exit 1
  else
    jsonVar=$( jq -r '.Parameters | .[] | .Value' $JSON_FULL )
    echo "$jsonVar" > $JSON
  fi
fi

for key in $( jq -r 'keys[]' $JSON ) ; do
  export $key="$( jq -r .$key $JSON )"
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

if [[ ${HEROKLES_INSTALL_DEPS:-true} == true ]] ; then
  echo "Running $installToolCmd."
  NODE_ENV=development $installToolCmd
fi

if jq -e '.scripts."herokles:build"' package.json >/dev/null ; then
  echo "Running $buildToolCmd herokles:build."
  $buildToolCmd herokles:build
fi

if jq -e '.scripts."herokles:prodinstall"' package.json >/dev/null ; then
  echo "Cleaning up all node_modules and running $buildToolCmd herokles:prodinstall."
  clean_modules
  $buildToolCmd herokles:prodinstall
fi

if [[ ! -z ${S3_FOLDER_NAME} ]] ; then
  if jq -e '.scripts."herokles:pack"' package.json >/dev/null ; then
    echo "Running $buildToolCmd herokles:pack."
    $buildToolCmd herokles:pack
  else
    echo "Packing the code."
    tar czf product.tgz .
  fi

  echo "Uploading build to S3."
  aws s3 cp product.tgz s3://${HEROKLES_AWS_S3_BUILDS_BUCKET}/${S3_FOLDER_NAME}/ >/dev/null
fi
