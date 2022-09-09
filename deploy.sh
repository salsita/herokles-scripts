#!/bin/bash

set -xeuo pipefail

touch /var/log/app.log
exec 2>&1 >( tee -a /var/log/app.log )

echo "Setting up logging."
if [ ! -z ${PAPERTRAIL_BASE64+x} ] ; then
  echo "${PAPERTRAIL_BASE64}" | base64 -d > /etc/log_files.yml
  remote_syslog &
fi

echo "Configuring aws cli."
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

echo "Getting environment variables."
JSON="$( aws ssm get-parameters --name ${PROJECT}-${ENV} | jq -r '.Parameters | .[] | .Value' )"
for key in $( echo "$JSON" | jq -r 'keys[]' ) ; do
  export $key="$( echo "$JSON" | jq -r .$key )"
done

echo "Getting build from S3."
aws s3 cp s3://${BUILD_AWS_S3_BUCKET}/${GITHUB_RUN_ID}/product.zip .

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
