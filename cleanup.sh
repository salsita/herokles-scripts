#!/bin/bash

set -euo pipefail

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
  awsparams=$(mktemp)
  deployments=$(mktemp)
  toclose=$(mktemp)
  trap 'rm -f "$awsparams" "$toclose" "$deployments"' EXIT INT
  echo "$AWS_PARAMS" | grep "^/$ns/pr-[0-9]\+" | grep -o 'pr-[0-9]\+$' | grep -o '[0-9]\+$' | sort -un > "$awsparams" || true
  kubectl get deployments -n "$ns" --no-headers -o custom-columns=":metadata.name" | grep -o 'pr-[0-9]\+$' | grep -o '[0-9]\+$' | sort -u > "$deployments" || true
  gh_repo=$(echo "$GH_REPOS" | grep "^$ns:" | cut -d ':' -f 2-) || {
    echo "no gh repo for $ns defined"
    continue
  }
  if [[ -n "$DAYS" ]]; then
    {
      gh pr list -R "$gh_repo" -s open -L 100000 --json number,createdAt | jq --arg date "$(date -v-"${DAYS}"d -u +"%Y-%m-%dT%H:%M:%SZ")" '.[] | select(.createdAt < $date) | .number'
      gh pr list -R "$gh_repo" -s closed -L 100000 --json number -q '.[].number'
    } | sort -u > "$toclose"
  else
    gh pr list -R "$gh_repo" -s closed -L 100000 --json number -q '.[].number' | sort -u > "$toclose"
  fi
#  echo -e "gh repo is $gh_repo
#Deployments of $ns:\n$(cat "$deployments" | sort -nu | tr '\n' ' ')
#AWS params of $ns:\n$(cat "$awsparams" | sort -nu | tr '\n' ' ')
#PRs in GH which shouldn't be in AWS/Herokles $ns:\n$(cat "$toclose" | sort -nu | tr '\n' ' ')"
#comm -12 awsparams.tmp to_close.tmp | while read param; do
#    echo "Closing pr-$param in $ns aws ssm"
#    #aws --profile herokles ssm delete-parameter --name /${ns}/${param} || echo "Parameterer /${ns}/${param} not found."
#    summary+="AWS parameter removed: $ns:$param"$'\n'
#done
#comm -12 deployments.tmp to_close.tmp | while read depl; do
#    echo "Unistalling pr-$depl in $ns Kube"
#    #helm uninstall -n ${ns} ${ns}-${depl} --wait --timeout ${HEROKLES_HELM_TIMEOUT:-3m1s}
#    summary+="Kube deployment removed: $ns:$depl"$'\n'
#done
while read param; do
    echo "Closing pr-$param in $ns aws ssm"
    #aws --profile herokles ssm delete-parameter --name /${ns}/${param} || echo "Parameter /${ns}/${param} not found."
    summary+="AWS parameter removed: $ns:$param"$'\n'
done < <(comm -12 "$awsparams" "$toclose")
while read depl; do
    echo "Uninstalling pr-$depl in $ns Kube"
    #helm uninstall -n ${ns} ${ns}-${depl} --wait --timeout ${HEROKLES_HELM_TIMEOUT:-3m1s}
    summary+="Kube deployment removed: $ns:$depl"$'\n'
done < <(comm -12 "$deployments" "$toclose")
#  for param in $aws_params_ns; do
#    if echo "$to_close" | grep -Fxq "$param"; then
#      echo "Closing pr-$param in $ns aws ssm"
#      #aws --profile herokles ssm delete-parameter --name /${ns}/${param} || echo "Parameterer /${ns}/${param} not found."
#      summary+="AWS parameter removed: $ns:$param"$'\n'
#    fi
#  done
#  for depl in $deployments; do
#    if echo "$to_close" | grep -Fxq "$depl"; then
#      echo "Unistalling pr-$depl in $ns Kube"
#      #helm uninstall -n ${ns} ${ns}-${depl} --wait --timeout ${HEROKLES_HELM_TIMEOUT:-3m1s}
#      summary+="Kube deployment removed: $ns:$depl"$'\n'
#    fi
#  done
done
echo "$summary" | sort || echo "No deployments in Herokles were closed"