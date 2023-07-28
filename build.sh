#!/bin/bash

set -euo pipefail

clean_modules() {
  local depth=1 to_del
  while true ; do
    to_del=$( find . -maxdepth $depth -type d -name node_modules )
    echo "$to_del"
    if [[ "$to_del" == '' ]] ; then
      return 0
    fi
    rm -rf "$to_del"
    depth=$(( depth + 1 ))
  done
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
  local JSON=$( mktemp )
  local JSON_TEMPLATE=$( mktemp )
  local JSON_FULL=$( mktemp )
  aws --profile herokles ssm get-parameters --name /${PROJECT}/${ENV} > $JSON_FULL

  if [[ $ENV == pr-${PR_NUM:-''} ]] ; then
    aws --profile herokles ssm get-parameters --name /${PROJECT}/prs > $JSON_TEMPLATE # get all template envs
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
    local update=$( mktemp )
    jq -r '.Parameters | .[] | .Value' $JSON_FULL > $update
    cat $update > $JSON
    jq -r '.Parameters | .[] | .Value' $JSON_TEMPLATE > $update
    cat $update > $JSON_TEMPLATE
    echo > $update
    local key val
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
      aws --profile herokles ssm put-parameter --type String --name /${PROJECT}/${ENV} --overwrite --value "$( jq -c . $JSON )"
    fi
  else
    if [[ ! -z $( jq -r '.InvalidParameters | .[]' $JSON_FULL ) ]] ; then
      echo "Environment variables for /${PROJECT}/${ENV} not found."
      exit 1
    else
      jq -r '.Parameters | .[] | .Value' $JSON_FULL > $JSON
    fi
  fi

  for key in $( jq -r 'keys[]' $JSON ) ; do
    export $key="$( jq -r .$key $JSON )"
  done

  local install_tool_cmd build_tool_cmd install_params=${HEROKLES_INSTALL_PARAMS:-}

  if [[ -f yarn.lock ]] ; then
    echo "Using Yarn."
    install_tool_cmd="yarn --immutable"
    build_tool_cmd=yarn
  else
    echo "Using NPM."
    install_tool_cmd="npm ci"
    build_tool_cmd="npm run"
  fi

  if [[ ${HEROKLES_INSTALL_DEPS:-true} == true ]] ; then
    echo "Running $install_tool_cmd."
    NODE_ENV=development $install_tool_cmd $install_params
  fi

  if jq -e '.scripts."herokles:build"' package.json >/dev/null ; then
    echo "Running $build_tool_cmd herokles:build."
    $build_tool_cmd herokles:build
  fi

  if jq -e '.scripts."herokles:prodinstall"' package.json >/dev/null ; then
    echo "Cleaning up all node_modules and running $build_tool_cmd herokles:prodinstall."
    clean_modules
    $build_tool_cmd herokles:prodinstall
  fi

  if [[ -n "${HEROKLES_AWS_S3_BUILDS_BUCKET_FOLDER:-}" ]] ; then
    if jq -e '.scripts."herokles:pack"' package.json >/dev/null ; then
      echo "Running $build_tool_cmd herokles:pack."
      $build_tool_cmd herokles:pack
    else
      echo "Packing the code."
      tar czf product.tgz .
    fi

    echo "Uploading build to S3."
    aws --profile herokles s3 cp product.tgz s3://${HEROKLES_AWS_S3_BUILDS_BUCKET_FOLDER}/ >/dev/null
  fi
}

main "$@"
