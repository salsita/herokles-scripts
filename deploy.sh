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

echo "Getting environment variables."
JSON_FULL=$( aws ssm get-parameters --name /${PROJECT}/${ENV} )
if [[ ! -z $( echo "$JSON_FULL" | jq -r '.InvalidParameters | .[]' ) ]] ; then
  echo "Missing environment variables paramater ${PROJECT}-${ENV}"
  exit 1
fi

JSON=$( echo "$JSON_FULL" | jq -r '.Parameters | .[] | .Value' )
for key in $( echo "$JSON" | jq -r 'keys[]' ) ; do
  export $key="$( echo "$JSON" | jq -r .$key )"
done

echo "Getting build from S3."
aws s3 cp s3://${HEROKLES_AWS_S3_BUILDS_BUCKET}/${GITHUB_RUN_ID}/product.zip . >/dev/null

echo "Unzipping product.zip."
unzip product.zip >/dev/null
rm -rf product.zip

echo "Starting the app."
if [[ -f ./scripts/herokles-run.sh ]] ; then
  ./scripts/herokles-run.sh
elif [[ -f yarn.lock ]] ; then
  yarn herokles:run
else
  npm run herokles:run
fi
