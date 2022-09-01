#!/bin/bash

set -euo pipefail

if [ ! -z ${RSYSLOG_CONFIG+x} ] ; then
  echo "$RSYSLOG_CONFIG" > /etc/log_files.yml
  remote_syslog &
  exec 2>&1 > /var/log/app.log
fi

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

aws s3 cp s3://${BUILD_AWS_S3_BUCKET}/${GITHUB_RUN_ID}/product.zip .

unzip product.zip
rm -rf product.zip

if [[ -f ./scripts/herokles-run.sh ]] ; then
  ./scripts/herokles-run.sh
elif [[ -f yarn.lock ]] ; then
  yarn herokles:run
else
  npm run herokles:run
fi
