#!/usr/bin/env bash

set -euo pipefail

# notice non-standard bash path - using this on mac os x

# check bash version because of associative array
if [ "${BASH_VERSION%%.*}" -lt 4 ]; then
    echo "Bash version 4 or greater is required, your version is $BASH_VERSION."
    exit 1
fi

# declaration of possible namespaces and repo, let's keep this at the beginning to keep it nice. should we later source this from external file? 
declare -A gh_repos=(
    ["ndim"]="salsita/ndimensional"
    ["aluliving"]="salsita/configurator-aluliving"
    ["moduline"]="salsita/configurator-moduline"
    ["secretshare"]="salsita/secretshare"
    ["chilli"]="salsita/configurator-chilli"
    ["centro"]="salsita/configurator-centro"
    ["easysteel"]="salsita/configurator-easysteel"
    ["kilo"]="salsita/configurator-kilo"
    ["latelier"]="salsita/configurator-latelier"
    ["conf-playground"]="salsita/configurator-sdk"
    ["car"]="salsita/configurator-car"
    ["azenco"]="salsita/configurator-azenco"
    ["phoenix"]="salsita/configurator-phoenix"
)

# check - all tools are installed
kubectl version --client
aws --version
gh version

# check - credentials for all endpoints
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

if aws ssm describe-parameters --query 'Parameters[].Name' --output json | grep -q secretshare ; then # this is tested on secretshare for now but how to do it?
    echo "You have access to AWS parameter store"
else
    echo "You don't have access to the right AWS parametere store"
    exit 1
fi

echo "All credentials set correctly, all tools are installed."

# list of all namespaces in Herokles cluster - we will use this as list of ns where cleaning will happen
echo
NAMESPACES=$( kubectl get ns --no-headers -o custom-columns=":metadata.name" | grep -vE '^kube-|^default$' | awk '/./' )
echo "Herokles now contains these namespaces:"
echo "$NAMESPACES"
echo # using quite a lot of simple echos for nicer output. how to do it?

# loop to show deployments and closed PRs for all defined namespaces
for ns in $NAMESPACES ; do
    echo
    echo "Project to clean: $ns"
    REPO=${gh_repos["$ns"]}
    echo "GitHub repository is $REPO"
    echo

    # show current running deployments
    DEPLOYMENTS=$( kubectl get deployments -n "$ns" --no-headers -o custom-columns=":metadata.name" )
    if ! echo "$DEPLOYMENTS" | grep -E -- "-pr-[0-9]+" > /dev/null ; then
        echo "No PR deployments running in Kube $ns namespace so skipping cleanup for this namespace"
        continue
    fi
    DEPLOYMENTS=$( echo "$DEPLOYMENTS" | grep -E -- "-pr-[0-9]+" ) > /dev/null
    echo "These deployment are in $ns namespace: ..."
    echo "$DEPLOYMENTS"
    echo

    # get numbers from deployment name - review, simplify, decode 
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

    # get closed PRs for repo
    echo "These PRs are closed in $REPO repository:"
    CLOSED_PRS=$( gh pr list -R "$REPO" -s closed -L 100000 --json number -q '.[].number' )
    echo "$CLOSED_PRS" | tr '\n' ' '
    echo

    # for testing, will be deleted 
    #DEPL_NUMBERS=$(echo -e "1\n2\n3\n4")
    #CLOSED_PRS=$(echo -e "3\n4\n5\n6")
    #echo "using DEPL_NUMBERS $(echo "$DEPL_NUMBERS" | tr '\n' ' ') and CLOSED_PRS $(echo "$CLOSED_PRS" | tr '\n' ' ') for testing"  
    #echo

    # get numbers of PRs to delete from Herokles
    echo
    for num in $DEPL_NUMBERS; do
        if echo "$CLOSED_PRS" | grep -Fxq "$num"; then
        TO_CLOSE+="$num "
        fi
    done
    # run unistall script for running deployments of closed PRs
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

# summary of job done
echo "Summary:"
if [ -n "${SUMMARY+x}" ]; then
    echo "$SUMMARY"
else
    echo "No deployments in Herokles were closed"
fi

# should we actually run two checks? one to check herokles and close deployments, one for aws to check parameter store and remove old parameters. what if PR was removed in Herokles but still sits in AWS? Current approach is: check kube, find closed prs, unistall deployment in kube AND remove AWS param.
# keeping testing part around line 106 for now
# script will show you that some PRs were uninstalled - not yet, uninstall_local.sh is harmless for now