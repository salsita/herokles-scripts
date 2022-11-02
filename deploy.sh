#!/bin/bash

set -euo pipefail

exec &> >( tee /var/log/app.log )

echo "Setting up logging."
if [ ! -z ${HEROKLES_PAPERTRAIL_BASE64+x} ] ; then
  echo "${HEROKLES_PAPERTRAIL_BASE64}" | base64 -d > /etc/log_files.yml
  remote_syslog -D --hostname $( hostname ) &
fi

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

echo "Getting build from S3."
aws s3 cp s3://${HEROKLES_AWS_S3_BUILDS_BUCKET}/${S3_FOLDER_NAME}/product.tgz . >/dev/null

echo "Unpacking product.zip."
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
