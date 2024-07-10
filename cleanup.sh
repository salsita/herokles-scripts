#!/bin/bash

set -euo pipefail

AWSPARAMS=$(mktemp)
DEPLOYMENTS=$(mktemp)
TO_CLOSE=$(mktemp)
SUMMARY=$(mktemp)
trap 'rm -f "$AWSPARAMS" "$TO_CLOSE" "$DEPLOYMENTS" "SUMMARY"' EXIT

DAYS=
read -p "Do you want to clean PRs older than a certain number of days? (y/n): " response
if [[ "$response" == "y" ]]; then
  read -p "Enter the number of days: " DAYS
  echo "PRs older than $DAYS days and closed PRs will be removed"
fi

kubectl config view | grep -q "herokles" || {
  echo "Something's wrong with kubectl. Not installed, wrong kubectl config, ..."
  exit 1
}
gh repo view salsita/herokles | grep -q "herokles" || {
  echo "Something's wrong with gh cli. Maybe login? (gh auth login)"
  exit 1
}
AWS_PARAMS=$(aws --profile herokles ssm describe-parameters --query 'Parameters[].Name' --output json | jq -r '.[]') || {
  echo "Unable to get AWS parameters"
  exit 1
}

GH_REPOS="aluliving:salsita/configurator-aluliving
moduline:salsita/configurator-moduline
secretshare:salsita/secretshare
chilli:salsita/configurator-chilli
centro:salsita/configurator-centro
easysteel:salsita/configurator-easysteel
kilo:salsita/configurator-kilo
latelier:salsita/configurator-latelier
conf-playground:salsita/configurator-sdk
car:salsita/configurator-car
azenco:salsita/configurator-azenco
azenco-quoting:salsita/azenco-quoting"
#phoenix:salsita/configurator-phoenix

NAMESPACES=$(kubectl get ns --no-headers -o custom-columns=":metadata.name" | grep -vE '^kube-|^default$') || {
  echo "Unable to get Kube namespaces"
  exit 1
}
echo -e "Kube namespaces:\n$NAMESPACES"

for ns in $NAMESPACES; do
  echo -e "\nProject to clean: $ns"
  echo > "$AWSPARAMS"
  echo > "$DEPLOYMENTS"
  echo > "$TO_CLOSE"
  echo "$AWS_PARAMS" | grep "^/$ns/pr-[0-9]\+" | grep -o 'pr-[0-9]\+$' | grep -o '[0-9]\+$' | sort -un > "$AWSPARAMS" || true
  kubectl get deployments -n "$ns" --no-headers -o custom-columns=":metadata.name" | grep -o 'pr-[0-9]\+$' | grep -o '[0-9]\+$' | sort -u > "$deployments" || true
  gh_repo=$(echo "$GH_REPOS" | grep "^$ns:" | cut -d ':' -f 2-) || {
    echo "no gh repo for $ns defined"
    continue
  }
  gh pr list -R "$gh_repo" -s closed -L 100000 --json number -q '.[].number' > "$TO_CLOSE"
  if [[ -n "$DAYS" ]]; then
    gh pr list -R "$gh_repo" -s open -L 100000 --json number,createdAt | jq --arg date "$(date -v-"${DAYS}"d -u +"%Y-%m-%dT%H:%M:%SZ")" '.[] | select(.createdAt < $date) | .number' >> "$TO_CLOSE"
  fi
  sort -uo "$TO_CLOSE" "$TO_CLOSE"
  comm -12 "$AWSPARAMS" "$TO_CLOSE" | while read param; do
    echo "Closing pr-$param in $ns aws ssm"
    if [[ "${1:-}" == "hot" ]]; then
      aws --profile herokles ssm delete-parameter --name /${ns}/${param} || echo "Parameterer /${ns}/${param} not found."
      echo "AWS parameter removed: $ns:$param" >> "$SUMMARY"
    else
      echo "Dry run: AWS parameter removed: $ns:$param" >> "$SUMMARY"
    fi
  done
  comm -12 "$DEPLOYMENTS" "$TO_CLOSE" | while read depl; do
    echo "Unistalling pr-$depl in $ns Kube"
    if [[ "${1:-}" == "hot" ]]; then
      helm uninstall -n ${ns} ${ns}-${depl} --wait --timeout ${HEROKLES_HELM_TIMEOUT:-3m1s}
      echo "Kube deployment removed: $ns:$depl" >> "$SUMMARY"
    else
      echo "Dry run: Kube deployment removed: $ns:$depl" >> "$SUMMARY"
    fi
  done
done
sort "$SUMMARY" | sort || echo "No deployments in Herokles were closed"