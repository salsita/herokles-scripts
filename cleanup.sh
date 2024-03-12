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

if gh repo view salsita/herokles  | grep -q "herokles"; then
    echo "You can view Salsita's Herokles GH repo."
else
    echo "Something's wrong with gh cli. Maybe login? (gh auth login)"
    exit 1
fi

echo "You are using this AWS identity:"
aws sts get-caller-identity

if aws ssm describe-parameters --query 'Parameters[].Name' --output json | grep -q secretshare ; then
    echo "You have access to AWS parameter store"
else
    echo "You don't have access to the right AWS parametere store"
    exit 1
fi

echo "All credentials set correctly, all tools are installed."

echo
NAMESPACES=$( kubectl get ns --no-headers -o custom-columns=":metadata.name" | grep -vE '^kube-|^default$' | awk '/./' )
echo "Herokles now contains these namespaces:"
echo "$NAMESPACES"
echo

for ns in $NAMESPACES ; do
    echo
    echo "Project to clean: $ns"
    if [ "$ns" = "secretshare" ]; then
        REPO="salsita/secretshare"
    elif [ "$ns" = "conf-playground" ]; then
        REPO="salsita/configurator-sdk"
    elif [ "$ns" = "azenco-quoting" ]; then
        REPO="salsita/azenco-quoting"
    elif [ "$ns" = "phoenix" ]; then
        echo "Skipping namespace $ns..."
        continue
    else
        REPO="salsita/configurator-$ns"
    fi
    echo "GitHub repository is $REPO"
    echo

    DEPLOYMENTS=$( kubectl get deployments -n "$ns" --no-headers -o custom-columns=":metadata.name" )
    if ! echo "$DEPLOYMENTS" | grep -E -- "-pr-[0-9]+" > /dev/null ; then
        echo "No PR deployments running in Kube $ns namespace so skipping cleanup for this namespace"
        continue
    fi
    DEPLOYMENTS=$( echo "$DEPLOYMENTS" | grep -E -- "-pr-[0-9]+" ) > /dev/null
    echo "These deployment are in $ns namespace: ..."
    echo "$DEPLOYMENTS"
    echo

    DEPL_NUMBERS=""
    for depl in $DEPLOYMENTS; do
        if echo "$depl" | grep -qE "${ns}-(postgres-)?pr-[0-9]+$"; then
        number=$(echo "$depl" | sed -E 's/.*pr-([0-9]+)$/\1/')
        DEPL_NUMBERS+="$number "
        fi
    done
    DEPL_NUMBERS=$(echo "$DEPL_NUMBERS" | xargs | tr ' ' '\n' | sort -n | uniq )
    echo "... -> these are the PRs (or parts of them) in Herokles: $(echo "$DEPL_NUMBERS" | tr '\n' ' ')"
    echo

    echo "These PRs are closed in $REPO repository:"
    CLOSED_PRS=$( gh pr list -R "$REPO" -s closed -L 100000 --json number -q '.[].number' )
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
            ./uninstall_local.sh $ns $pr || exit=$?
            if [ -z ${exit+x} ]; then
                echo "Unistall.sh for $ns:$pr went well."
                SUMMARY+="$ns:$pr uninstalled."$'\n'
            else
                echo "Unistall.sh for $ns:$pr crashed with exit code $exit."
                SUMMARY+="$ns:$pr crashed with exit code $exit."$'\n'
                unset exit
            fi
            unset TO_CLOSE
        done
    else
        echo "nothing to close in namespace $ns"
    fi
done

echo "Summary:"
if [ -n "${SUMMARY+x}" ]; then
    echo "$SUMMARY"
else
    echo "No deployments in Herokles were closed"
fi