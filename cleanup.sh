#!/bin/bash

set -euo pipefail

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

NAMESPACES=$(kubectl get ns --no-headers -o custom-columns=":metadata.name" | grep -vE '^kube-|^default$' | awk '/./') || {
    echo "Unable to get Kube namespaces"
    exit 1
}
echo -e "Kube namespaces:\n$NAMESPACES\n"

for ns in $NAMESPACES; do
    echo -e "\nProject to clean: $ns"
    AWS_PARAMS_NS=$(echo "$AWS_PARAMS" | grep "^/$ns/pr-[0-9]\+" | grep -o 'pr-[0-9]\+$' | grep -o '[0-9]\+$' | sort -un) || AWS_PARAMS_NS=""
    DEPLOYMENTS=$(kubectl get deployments -n "$ns" --no-headers -o custom-columns=":metadata.name" | grep -o 'pr-[0-9]\+$' | grep -o '[0-9]\+$' | sort -un) || DEPLOYMENTS=""
    GH_REPO=$(echo "$GH_REPOS" | grep "^$ns:" | sed 's/^[^:]*://') || {
        echo -e "no gh repo for $ns defined\n"
        continue
    }
    CLOSED_PRS=$(gh pr list -R "$GH_REPO" -s closed -L 100000 --json number -q '.[].number' | sort -nu)
    echo -e "gh repo is $GH_REPO\nDeployments of $ns:\n$(echo "$DEPLOYMENTS" | tr '\n' ' ')\nAWS params of $ns:\n$(echo "$AWS_PARAMS_NS" | tr '\n' ' ')\nClosed PRs in GH for $ns:\n$(echo "$CLOSED_PRS" | tr '\n' ' ')\n"
    for param in $AWS_PARAMS_NS; do
        if [[ " ${CLOSED_PRS[*]} " =~ ${param} ]]; then
            echo "Closing pr-$param in $ns aws ssm"
            #aws --profile herokles ssm delete-parameter --name /${ns}/${param} || echo "Parameterer /${ns}/${param} not found."
            SUMMARY+="AWS parameter removed: $ns:$param"$'\n'
        fi
    done
    for depl in $DEPLOYMENTS; do
        if [[ " ${CLOSED_PRS[*]} " =~ ${depl} ]]; then
            echo "Unistalling pr-$depl in $ns Kube"
            #helm uninstall -n ${ns} ${ns}-${depl} --wait --timeout ${HEROKLES_HELM_TIMEOUT:-3m1s}
            SUMMARY+="Kube deployment removed: $ns:$depl"$'\n'
        fi
    done
done

echo "$SUMMARY" | sort || echo "No deployments in Herokles were closed"
