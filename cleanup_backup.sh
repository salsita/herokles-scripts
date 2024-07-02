#!/bin/bash

set -euo pipefail

kubectl version --client
aws --version
gh version
if kubectl config view | grep -q "herokles"; then
    echo "You have the right Herokles kubectl config, let's go on!"
else
    echo "Nice try, but this is not Herokles kubectl config..."
    exit 1
fi
if gh repo view salsita/herokles | grep -q "herokles"; then
    echo "You can view Salsita's Herokles GH repo."
else
    echo "Something's wrong with gh cli. Maybe login? (gh auth login)"
    exit 1
fi
echo "You are using this AWS identity:"
aws --profile herokles sts get-caller-identity
AWS_PARAMS=$(aws --profile herokles ssm describe-parameters --query 'Parameters[].Name' --output json)
if echo "$AWS_PARAMS" | grep -q secretshare; then
    echo "You have access to AWS parameter store"
else
    echo "You don't have access to the right AWS parametere store"
    exit 1
fi
echo "All credentials set correctly, all tools are installed."

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

echo
NAMESPACES=$(kubectl get ns --no-headers -o custom-columns=":metadata.name" | grep -vE '^kube-|^default$' | awk '/./')
echo "Herokles now contains these namespaces:"
echo "$NAMESPACES"
echo
for ns in $NAMESPACES; do
    echo
    echo "Project to clean: $ns"
    if ! echo "$GH_REPOS" | grep "^$ns:" >/dev/null; then
        echo "GH repo for $ns namespace not defined, skipping"
        SUMMARY+="Skipping $ns - GH repo not defined."$'\n'
        continue
    fi
    MY_GH_REPO=$(echo "$GH_REPOS" | grep "^$ns:")
    REPO="${MY_GH_REPO#*:}"
    echo "GitHub repository is $REPO"
    echo
    DEPLOYMENTS=$(kubectl get deployments -n "$ns" --no-headers -o custom-columns=":metadata.name")
    if ! echo "$DEPLOYMENTS" | grep -E -- "-pr-[0-9]+" >/dev/null; then
        echo "No PR deployments running in Kube $ns namespace"
        PR_IN_KUBE=false
    else
        echo "PR deployments running in Kube $ns namespece"
        PR_IN_KUBE=true
        DEPLOYMENTS=$(echo "$DEPLOYMENTS" | grep -E -- "-pr-[0-9]+") >/dev/null
        echo "These deployment are in $ns kube namespace: ..."
        echo "$DEPLOYMENTS"
        echo
    fi
    AWS_PARAMS_NS=$(echo "$AWS_PARAMS" | grep -E "/$ns(/|$)")
    if ! echo "$AWS_PARAMS_NS" | grep -E -- "pr-[0-9]+" >/dev/null; then
        echo "No PR parameters present in AWS for $ns"
        PR_IN_AWS=false
    else
        echo "Parameters existing in $ns AWS parameter store"
        PR_IN_AWS=true
        AWS_PARAMS_NS=$(echo "$AWS_PARAMS_NS" | grep -E -- "pr-[0-9]+") >/dev/null
        echo "These parameters are in $ns AWS parameter store: ..."
        echo "$AWS_PARAMS_NS"
    fi
    if [ "$PR_IN_KUBE" = false ] && [ "$PR_IN_AWS" = false ]; then
        echo "no PR in Kube or AWS parameter store so skipping cleanup for this namespace"
        SUMMARY+="Skipping $ns - no PRs in kube or aws"$'\n'
        unset PR_IN_KUBE
        unset PR_IN_AWS
        unset AWS_PARAMS_NS
        continue
    fi
    echo "namespace $ns: kube has deployments: $PR_IN_KUBE, aws has parameters: $PR_IN_AWS"
    echo
    echo "kube part"
    echo
    if [ "$PR_IN_KUBE" = true ]; then
        DEPL_NUMBERS=""
        for depl in $DEPLOYMENTS; do
            if echo "$depl" | grep -qE "${ns}-(postgres-)?pr-[0-9]+$"; then
                number=$(echo "$depl" | sed -E 's/.*pr-([0-9]+)$/\1/')
                DEPL_NUMBERS+="$number "
            fi
        done
        DEPL_NUMBERS=$(echo "$DEPL_NUMBERS" | xargs | tr ' ' '\n' | sort -n | uniq)
        echo "... -> these are the PRs (or parts of them) in Herokles: $(echo "$DEPL_NUMBERS" | tr '\n' ' ')"
        echo
        echo "These PRs are closed in $REPO repository:"
        CLOSED_PRS=$(gh pr list -R "$REPO" -s closed -L 100000 --json number -q '.[].number')
        echo "$CLOSED_PRS" | tr '\n' ' '
        echo
        echo
        for num in $DEPL_NUMBERS; do
            if echo "$CLOSED_PRS" | grep -Fxq "$num"; then
                TO_CLOSE+="$num "
            fi
        done
        if [ -n "${TO_CLOSE+x}" ]; then
            echo "These PRs (or their parts) are still sitting in Herokles $ns namespace and will be deleted: $TO_CLOSE"
            for pr in $TO_CLOSE; do
                echo "Running unistall script for PR $pr, namespace $ns and repo $REPO"
                echo "Uninstall Helm deployment $ns:$pr"
                echo "#command for actual cleaning commented"
                #helm uninstall -n ${ns} ${ns}-${pr} --wait --timeout ${HEROKLES_HELM_TIMEOUT:-3m1s}
                echo "Helm unistall for $ns:$pr went well."
                SUMMARY+="Kubernetes deployment deleted - $ns:$pr "$'\n'
            done
        else
            echo "nothing to close in namespace $ns"
            SUMMARY+="nothing to close in Kube namespace $ns"$'\n'
        fi
        unset TO_CLOSE
    fi
    echo
    echo "aws part"
    echo
    if [ "$PR_IN_AWS" = true ]; then
        PARAM_NUMBERS=$(echo "$AWS_PARAMS_NS" | grep -oE 'pr-[0-9]+' | sed 's/pr-//' | xargs | tr ' ' '\n' | sort -n | uniq)
        echo "... -> these are the PRs in AWS parameter store: $(echo "$PARAM_NUMBERS" | tr '\n' ' ')"
        echo
        echo "These PRs are closed in $REPO repository:"
        CLOSED_PRS=$(gh pr list -R "$REPO" -s closed -L 100000 --json number -q '.[].number')
        echo "$CLOSED_PRS" | tr '\n' ' '
        echo
        for param in $PARAM_NUMBERS; do
            if echo "$CLOSED_PRS" | grep -Fxq "$param"; then
                TO_REMOVE+="$param "
            fi
        done
        if [ -n "${TO_REMOVE+x}" ]; then
            echo
            echo "These PRs from $ns still have parameters in AWS and will be removed: $TO_REMOVE"
            echo
            for pr in $TO_REMOVE; do
                echo "Remove AWS parameter $ns:$pr"
                echo "#command for actual cleaning commented"
                #aws --profile herokles ssm delete-parameter --name /${ns}/${pr} || echo "Parameterer /${ns}/${pr} not found."
                echo "AWS parameter remove for $ns:$pr went well."
                SUMMARY+="AWS parameter removed for $ns:$pr."$'\n'
            done
        else
            echo "nothing to remove from AWS in namespace $ns"
            SUMMARY+="nothing to remove from AWS in namespace $ns"$'\n'
        fi
        unset TO_REMOVE
    fi
    unset PR_IN_KUBE
    unset PR_IN_AWS
    unset AWS_PARAMS_NS
done
echo
echo "Summary:"
if [ -n "${SUMMARY+x}" ]; then
    echo "$SUMMARY" | sort
else
    echo "No deployments in Herokles were closed"
fi
