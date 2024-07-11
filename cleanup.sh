#!/bin/bash

set -euo pipefail

DAYS=
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

function cleanAwsHot() {
  aws --profile herokles ssm delete-parameter --name /${ns}/${param} || echo "Parameterer /${ns}/${param} not found."
  echo "AWS parameter removed: $ns:$param" >> "$SUMMARY"
}
function cleanKubeHot() {
  helm uninstall -n ${ns} ${ns}-${depl} --wait --timeout ${HEROKLES_HELM_TIMEOUT:-3m1s}
  echo "Kube deployment removed: $ns:$depl" >> "$SUMMARY"
}
function cleanAwsDry() {
  echo "Dry run: AWS parameter removed: $ns:$param" >> "$SUMMARY"
}
function cleanKubeDry() {
  echo "Dry run: Kube deployment removed: $ns:$depl" >> "$SUMMARY"
}
function cleanRepo {
  for ns in $NAMESPACES; do
    echo "Project to clean: $ns"
    echo >"$AWS_PARAMS_PATH"
    echo >"$DEPLOYMENTS_PATH"
    echo >"$TO_CLOSE_PATH"
    echo "$AWS_PARAMS" \
      | grep "^/$ns/pr-[0-9]\+" \
      | grep -o 'pr-[0-9]\+$' \
      | grep -o '[0-9]\+$' \
      | sort -u >"$AWS_PARAMS_PATH" || true
    kubectl get deployments -n "$ns" --no-headers -o custom-columns=":metadata.name" \
      | grep -o 'pr-[0-9]\+$' \
      | grep -o '[0-9]\+$' \
      | sort -u >"$DEPLOYMENTS_PATH" || true
    gh_repo=$(echo "$GH_REPOS" | grep "^$ns:" | cut -d ':' -f 2-) || {
      echo "no gh repo for $ns defined"
      continue
    }
    gh pr list -R "$gh_repo" -s closed -L 100000 --json number -q '.[].number' > "$TO_CLOSE_PATH"
    if [[ -n "$DAYS" ]]; then
      gh pr list -R "$gh_repo" -s open -L 100000 --json number,createdAt \
        | jq --arg date "$(date -v-"${DAYS}"d -u +"%Y-%m-%dT%H:%M:%SZ")" '.[] | select(.createdAt < $date) | .number' >> "$TO_CLOSE_PATH"
    fi
    sort -uo "$TO_CLOSE_PATH" "$TO_CLOSE_PATH"
    comm -12 "$AWS_PARAMS_PATH" "$TO_CLOSE_PATH" | while read param; do
      echo "Closing pr-$param in $ns aws ssm"
      cleanAws$RUN
    done
    comm -12 "$DEPLOYMENTS_PATH" "$TO_CLOSE_PATH" | while read depl; do
      echo "Unistalling pr-$depl in $ns Kube"
      cleanKube$RUN
    done
  done
}
function cleanup() {
    rm -f "$AWS_PARAMS_PATH" "$TO_CLOSE_PATH" "$DEPLOYMENTS_PATH" "$SUMMARY"
}
function main() {
  RUN=${1:-'Dry'}
  AWS_PARAMS_PATH=$(mktemp)
  DEPLOYMENTS_PATH=$(mktemp)
  TO_CLOSE_PATH=$(mktemp)
  SUMMARY=$(mktemp)

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
  AWS_PARAMS=$(aws --profile herokles ssm describe-parameters --query 'Parameters[].Name' --output json | jq -r '.[]') || { #naming
    echo "Unable to get AWS parameters"
    exit 1
  }
  NAMESPACES=$(kubectl get ns --no-headers -o custom-columns=":metadata.name" | grep -vE '^kube-|^default$') || {
    echo "Unable to get Kube namespaces"
    exit 1
  }
  echo -e "Kube namespaces:\n$NAMESPACES"

  cleanRepo "$@"

  sort "$SUMMARY" | sort || echo "No deployments in Herokles were closed"
}

trap cleanup EXIT
main "$@"