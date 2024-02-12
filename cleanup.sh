#!/opt/homebrew/bin/bash
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
    echo "Get started with GitHub CLI - please run:  gh auth login"
    exit 1
fi

# !!! add AWS credentials check
echo "There is no AWS credentials check yet"
echo "All credentials set correctly, all tools are installed."

# list of all namespaces in Herokles cluster - we will use this as list of ns where cleaning will happen
echo ""
#NAMESPACES=$( kubectl get ns --no-headers -o custom-columns=":metadata.name" | grep -vE '^kube-|^default$' | awk '/./' )
# use azenco for testing
NAMESPACES=azenco
echo "Herokles now contains these namespaces:"
echo "$NAMESPACES"
echo ""

# loop to show deployments and closed PRs for all defined namespaces
for ns in $NAMESPACES ; do
    echo ""
    echo "Project to clean: $ns"
    REPO=${gh_repos["$ns"]}
    echo "GitHub repository is $REPO"
    echo ""

    # show current running deployments
    DEPLOYMENTS=$( kubectl get deployments -n "$ns" --no-headers -o custom-columns=":metadata.name" )
    if ! echo "$DEPLOYMENTS" | grep -E -- "-pr-[0-9]+" > /dev/null ; then
        echo "No PR deployments running in Kube $ns namespace so skipping cleanup for this namespace"
         continue
    fi
    DEPLOYMENTS=$( echo "$DEPLOYMENTS" | grep -E -- "-pr-[0-9]+" ) > /dev/null
    echo "These deployment are in $ns namespace: ..."
    echo "$DEPLOYMENTS"
    echo ""

    # get numbers from deployment name - review, simplify, decode 
    DEPL_NUMBERS=""
    for depl in $DEPLOYMENTS; do
        if echo "$depl" | grep -qE "${ns}-(postgres-)?pr-[0-9]+$"; then
        number=$(echo "$depl" | sed -E 's/.*pr-([0-9]+)$/\1/')
        DEPL_NUMBERS+="$number "
        fi
    done
    DEPL_NUMBERS=$(echo "$DEPL_NUMBERS" | xargs | tr ' ' '\n' | sort -n | uniq ) # | tr '\n' ' '
    echo "... -> these are the PRs (or parts of them) in Herokles: $(echo "$DEPL_NUMBERS" | tr '\n' ' ')"
    echo ""

    # get closed PRs for repo
    echo "These PRs are closed in $REPO repository:"
    CLOSED_PRS=$( gh pr list -R "$REPO" -s closed -L 100000 --json number -q '.[].number' )
    echo "$CLOSED_PRS" | tr '\n' ' '
    echo ""
    echo ""
    echo "let's show all closed PRs which still sits in Herokles"
    

done

exit 0

#-------------------------------------------
# let's just test workflow with azenco repo for now
# which repo am I cleaning?

REPO=salsita/configurator-azenco
KUBE_NS=azenco
echo ""
echo "Let's clean $REPO repository"
echo "Kube NS is $KUBE_NS"

# get open PRs for repo

echo ""
echo "These PRs are closed in $REPO repository:"
CLOSED_PRS=$( gh pr list -R $REPO -s closed -L 100000 --json number -q '.[].number' )
echo "$CLOSED_PRS"

# show current running deployments

echo ""
echo "These PRs are running in $KUBE_NS namespace as deployments:"
kubectl get deployments -n azenco | grep -E -- "-pr-[0-9]+" 