#!/bin/bash

set -euo pipefail

readonly LOG_FILE=/var/log/app.log

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

function start() {
  echo "Starting main function."
  [[ -d ~/.aws ]] || set_aws_creds

  echo "Getting build from S3."
  aws --profile herokles s3 cp \
    s3://${HEROKLES_AWS_S3_BUILDS_BUCKET}/${HEROKLES_AWS_S3_BUILDS_FOLDER}/product.tgz \
    . \
    >/dev/null

  echo "Unpacking product.tgz."
  tar xzf product.tgz
  rm -rf product.tgz

  echo "Starting the app."
  if [[ -f ./herokles/run.sh ]] ; then
    ./herokles/run.sh
  elif [[ -f yarn.lock ]] ; then
    yarn herokles:run
  else
    npm run herokles:run
  fi
  echo "App died or finished."
}

function main() {
  touch $LOG_FILE
  tail -f $LOG_FILE &

  if [ -n ${HEROKLES_PAPERTRAIL_BASE64:-} ] ; then
    echo "${HEROKLES_PAPERTRAIL_BASE64}" | base64 -d > /etc/log_files.yml
    remote_syslog -D --hostname $( hostname ) &
    sleep 3
    echo "Remote logging initialized." >> $LOG_FILE
  fi
  start &>> $LOG_FILE
}

main "$@"
