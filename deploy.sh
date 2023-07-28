#!/bin/bash

set -euo pipefail

readonly LOG_FILE=/var/log/app.log

function start() {
  echo "Starting main function."
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

  echo "Getting build from S3."
  aws --profile herokles s3 cp s3://${HEROKLES_AWS_S3_FOLDER_NAME}/product.tgz . >/dev/null

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
