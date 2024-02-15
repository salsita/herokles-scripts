#!/bin/bash

set -euo pipefail

PROJECT=$1
ENV="pr-$2"

echo "Deleting environment variables: $PROJECT:$ENV"
echo "#command for actual cleaning commented"
#aws --profile herokles ssm delete-parameter --name /${PROJECT}/${ENV} || echo "Parameterer /${PROJECT}/${ENV} not found."

echo "Uninstall Helm deployment $PROJECT:$ENV"
echo "#command for actual cleaning commented"
#helm uninstall -n ${PROJECT} ${PROJECT}-${ENV} --wait --timeout ${HEROKLES_HELM_TIMEOUT:-3m1s}
