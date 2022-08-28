#!/bin/bash

set -euo pipefail

ENV=${1:=$ENV}

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
