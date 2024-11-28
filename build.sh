#!/bin/bash

set -euo pipefail

function clean_modules() {
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

  echo "Getting environment variables."
  local json=$( mktemp )
  local json_template=$( mktemp )
  local json_full=$( mktemp )
  aws --profile herokles ssm get-parameters --name /${PROJECT}/${ENV} > $json_full

  if [[ $ENV == pr-${PR_NUM:-''} ]] ; then
    aws --profile herokles ssm get-parameters --name /${PROJECT}/prs > $json_template # get all template envs
    if [[ ! -z $( jq -r '.InvalidParameters | .[]' $json_template ) ]] ; then
      echo "Template PR variables /${PROJECT}/prs not found."
      exit 1
    fi
    if [[ ! -z $( jq -r '.InvalidParameters | .[]' $json_full ) ]] ; then # check if it's a new PR
      echo "New PR - setting to copy from /${PROJECT}/prs."
      echo '{ "Parameters": [ { "Value": { } } ] }' > $json_full
    fi
    # find new envs in /PROJECT/prs template, fill them in and push
    # $update file works a) for retrieving only the env var values from a rich JSON and b) as a condition checker for when to update pr-<num> parameter
    local update=$( mktemp )
    jq -r '.Parameters | .[] | .Value' $json_full > $update
    cat $update > $json
    jq -r '.Parameters | .[] | .Value' $json_template > $update
    cat $update > $json_template
    echo > $update
    local key val
    for key in $( jq -r 'keys[]' $json_template ) ; do
      if [[ $( jq -r .$key $json ) == null ]] ; then
        cat $json | jq ".${key}=\"$( jq -r .$key $json_template )\"" > $update
        cat $update > $json
      fi
    done
    if [[ -f ./herokles/set-custom-pr-envs.sh ]] ; then
      ./herokles/set-custom-pr-envs.sh \
      | while read line ; do
        key=$( echo "$line" | cut -d'=' -f1 )
        val=$( echo "$line" | cut -d'=' -f2- )
        if [[ $( jq -r .$key $json ) == null ]] ; then
          cat $json | jq ".${key}=\"${val}\"" > $update
          cat $update > $json
        fi
      done
    fi
    if [[ ! -z $( cat $update ) ]] ; then
      echo "Uploading new environment variables."
      aws --profile herokles ssm put-parameter --type String --name /${PROJECT}/${ENV} --overwrite --value "$( jq -S . $json )"
    fi
  else
    if [[ ! -z $( jq -r '.InvalidParameters | .[]' $json_full ) ]] ; then
      echo "Environment variables for /${PROJECT}/${ENV} not found."
      exit 1
    else
      jq -r '.Parameters | .[] | .Value' $json_full > $json
    fi
  fi

  # Invoke optional script to process the JSON var object
  if [[ -f ./herokles/set-vars-hook.sh ]] ; then
    json_temp=$( mktemp )
    cp $json $json_temp
    ./herokles/set-vars-hook.sh $json_temp
    if jq . < $json_temp >/dev/null 2>&1; then
      if ! diff -q $json $json_temp; then
        echo "Uploading new environment variables."
        cp $json_temp $json
        aws --profile herokles ssm put-parameter --type String --name /${PROJECT}/${ENV} --overwrite --value "$( jq -S . $json )"
      fi
    else
      echo "Invalid JSON, skipping env processing hook output"
    fi
    rm -f $json_temp
  fi

  for key in $( jq -r 'keys[]' $json ) ; do
    export $key="$( jq -r .$key $json )"
  done

  local install_tool_cmd build_tool_cmd install_params=${HEROKLES_INSTALL_PARAMS:-}

  if [[ -f pnpm-lock.yaml ]] ; then
    echo "Using PNPM."
    npm install -g --force $( jq -r .packageManager package.json )
    install_tool_cmd="pnpm install"
    build_tool_cmd=pnpm
  elif [[ -f yarn.lock ]] ; then
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

  if [[ -n "${HEROKLES_AWS_S3_BUILDS_BUCKET:-}${HEROKLES_AWS_S3_BUILDS_FOLDER:-}" ]] ; then
    if jq -e '.scripts."herokles:pack"' package.json >/dev/null ; then
      echo "Running $build_tool_cmd herokles:pack."
      $build_tool_cmd herokles:pack
    else
      echo "Packing the code."
      tar czf product.tgz .
    fi

    echo "Uploading build to S3."
    aws --profile herokles s3 cp \
      product.tgz \
      s3://${HEROKLES_AWS_S3_BUILDS_BUCKET}/${HEROKLES_AWS_S3_BUILDS_FOLDER}/product.tgz \
      >/dev/null
  fi
}

main "$@"
