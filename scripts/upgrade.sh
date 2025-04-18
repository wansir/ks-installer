#!/bin/bash

set -e

CORE_CHART_VERSION=${CORE_CHART_VERSION:-"1.1.5"}
TAG=${TAG:-"v4.1.3"}
KS_UPGRADE_TAG=${KS_UPGRADE_TAG:-$TAG}
EXTENSION_VERSION=${EXTENSION_VERSION:-"v1.1.5"}
IMAGE_REGISTRY=${IMAGE_REGISTRY:-"docker.io"}
EXTENSION_IMAGE_REGISTRY=${EXTENSION_IMAGE_REGISTRY:-""}


EXTENSION_REGISTRY_ARG=""
if [ -n "$EXTENSION_IMAGE_REGISTRY" ]; then
  EXTENSION_REGISTRY_ARG="--set extension.imageRegistry=$EXTENSION_IMAGE_REGISTRY"
fi


# parse command line arguments and check
[ ! -n "$1" ] && echo "usage: $0 <host|member|gateway>" && exit 1

role="$1"

[[ "$role" != "host" ]] && [[ "$role" != "member" ]] && [[ "$role" != "gateway" ]] && echo "usage: $0 <host|member|gateway>" && exit 1

gateway_name=""

if [[ "$role" == "gateway" ]] && [ -n "$2" ]; then
  gateway_name="$2"
fi

# check ks-core-values.yaml
[[ ! -e ks-core-values.yaml ]] && echo "ks-core-values.yaml not found in current directory" && exit 1

# check kubectl and helm
if ! command -v kubectl &> /dev/null; then
  echo "kubectl could not be found"
  exit
fi

if ! command -v helm &> /dev/null; then
  echo "helm could not be found"
  exit
fi

# check if ks-core directory exists
if [ ! -d charts/ks-core ]; then
  mkdir -p charts
  pushd charts
  helm pull https://charts.kubesphere.io/main/ks-core-$CORE_CHART_VERSION.tgz --untar
  popd
fi

chart="charts/ks-core"

# count down
function count_down() {
    for i in $(seq $1 -1 1); do
        echo -ne "\rStarting upgrade in $i seconds"
        sleep 1
    done
    echo
}

function confirm_image() {
    echo

    read -p "Please make sure the target version is $TAG, can be set by env 'TAG' (yes/no): " confirm
    [[ "$confirm" != "yes" ]] && echo "upgrade cancelled" && exit 1

    echo

    read -p "Please make sure the image registry is $IMAGE_REGISTRY, can be set by env 'IMAGE_REGISTRY' (yes/no): " confirm
    [[ "$confirm" != "yes" ]] && echo "upgrade cancelled" && exit 1

    # check if the docker exists
    echo "pulling $IMAGE_REGISTRY/kubesphere/ks-upgrade:$KS_UPGRADE_TAG"
    if command -v docker &> /dev/null; then
        docker pull $IMAGE_REGISTRY/kubesphere/ks-upgrade:$KS_UPGRADE_TAG
        if [ $? -ne 0 ]; then
            echo "docker pull $IMAGE_REGISTRY/kubesphere/ks-upgrade:$KS_UPGRADE_TAG failed"
            exit 1
        fi
    elif command -v crictl &> /dev/null; then
        crictl pull $IMAGE_REGISTRY/kubesphere/ks-upgrade:$KS_UPGRADE_TAG
        if [ $? -ne 0 ]; then
            echo "crictl pull $IMAGE_REGISTRY/kubesphere/ks-upgrade:$KS_UPGRADE_TAG failed"
            exit 1
        fi
    fi

    echo
}

function fill_etcd_endpoint_ips(){
    CURRENT_VALUE=$(kubectl get  cc ks-installer -n kubesphere-system -o jsonpath='{.spec.etcd.endpointIps}' 2>/dev/null)

    ETCD_IPS=$(kubectl get endpoints -n kube-system etcd --ignore-not-found=true -o=jsonpath='{.subsets[*].addresses[*].ip}' | tr ' ' ',')

    if [[ -z "$CURRENT_VALUE" || "$CURRENT_VALUE" == "localhost" ]]; then
        echo "etcd endpointIps is empty or localhost, will be filled with $ETCD_IPS"
        if [[ -z "$CURRENT_VALUE" ]]; then
            kubectl patch cc ks-installer -n kubesphere-system --type='json' -p="[{'op': 'add', 'path': '/spec/etcd/endpointIps', 'value': '${ETCD_IPS}'}]"
        else
            kubectl patch cc  ks-installer -n kubesphere-system --type='json' -p="[{'op': 'replace', 'path': '/spec/etcd/endpointIps', 'value': '${ETCD_IPS}'}]"
        fi
    fi
}

function check_pending_upgrade() {
    RELEASE_NAME="ks-core"
    NAMESPACE="kubesphere-system"


    RELEASE_JSON=$(helm status "$RELEASE_NAME" -n "$NAMESPACE" --output json)
    STATUS=$(echo "$RELEASE_JSON" | jq -r '.info.status')
    REVISION=$(echo "$RELEASE_JSON" | jq -r '.version')

    if [ "$STATUS" == "pending-upgrade" ]; then
      echo "Release [$RELEASE_NAME]: another operation (install/upgrade/rollback) is in progress is in progress"

      SECRET_NAME="sh.helm.release.v1.${RELEASE_NAME}.v${REVISION}"

      echo "Detected that you might need to manually delete the previous Helm release secret:"
      echo "   kubectl delete secret $SECRET_NAME -n $NAMESPACE"
      exit 1
    fi
}

function upgrade_cluster() {
    # confirm the upgrade
    kubectl get nodes -o=custom-columns=NAME:.metadata.name,STATUS:.status.conditions[-1].type,INTERNAL-IP:.status.addresses[0].address,VERSION:.status.nodeInfo.kubeletVersion
    echo
    echo

    read -p "Please make sure this cluster is $role (yes/no): " confirm
    [[ "$confirm" != "yes" ]] && echo "upgrade cancelled" && exit 1

    confirm_image

    count_down 10

    echo "**************************************************"
    echo "Backup critical resources in the system workspace."
    echo "**************************************************"
    backup

    echo "**************************************************"
    echo "Upgrade KubeSphere"
    echo "**************************************************"

    echo "stop ks-installer"
    kubectl -n kubesphere-system get deploy ks-installer && kubectl -n kubesphere-system scale --replicas=0 deploy ks-installer

    fill_etcd_endpoint_ips

    echo "remove redis"
    helm del -n kubesphere-system ks-redis &> /dev/null || true
    kubectl delete pvc -n kubesphere-system -l app=redis-ha --ignore-not-found || true
    kubectl delete deploy -n kubesphere-system -l app.kubernetes.io/managed-by!=Helm --field-selector metadata.name=redis --ignore-not-found || true
    kubectl delete svc -n kubesphere-system -l app.kubernetes.io/managed-by!=Helm --field-selector metadata.name=redis --ignore-not-found || true
    kubectl delete secret -n kubesphere-system -l app.kubernetes.io/managed-by!=Helm --field-selector metadata.name=redis-secret --ignore-not-found || true
    kubectl delete cm -n kubesphere-system -l app.kubernetes.io/managed-by!=Helm --field-selector metadata.name=redis-configmap --ignore-not-found || true
    kubectl delete pvc -n kubesphere-system -l app.kubernetes.io/managed-by!=Helm --field-selector metadata.name=redis-pvc --ignore-not-found || true

    args=""
    redis_enabled=$(kubectl get cc -n kubesphere-system ks-installer -o jsonpath='{.status.redis.status}')
    redis_ha_enabled=$(kubectl get cc -n kubesphere-system ks-installer -o jsonpath='{.spec.common.redis.enableHA}')

    if [ "$redis_enabled" == "enabled" ]; then
      args="--set ha.enabled=true"
    fi

    if [ "$redis_ha_enabled" == "true" ]; then
      args="$args --set redisHA.enabled=true"
    fi

    echo "apply CRDs"
    kubectl -n kubesphere-system delete job prepare-upgrade --ignore-not-found
    helm template -s templates/prepare-upgrade-job.yaml -n kubesphere-system --release-name \
        --set upgrade.prepare=true,upgrade.image.registry=$IMAGE_REGISTRY,upgrade.image.tag=$KS_UPGRADE_TAG \
        $EXTENSION_REGISTRY_ARG \
        --set global.imageRegistry=$IMAGE_REGISTRY,global.tag=$TAG \
        -f ks-core-values.yaml \
        $chart --dry-run=server | kubectl -n kubesphere-system apply --wait -f - && kubectl -n kubesphere-system wait --for=condition=complete --timeout=600s job/prepare-upgrade

    helm show crds  $chart | kubectl apply -f -


    echo "review your upgrade values.yaml and make sure the extension configs matches the extension you published, you have 10 seconds before upgrade starts."
    sleep 10



    helm upgrade -n kubesphere-system ks-core $chart --debug --wait --timeout 30m \
         --set multicluster.role=$role \
         --set upgrade.image.registry=$IMAGE_REGISTRY,upgrade.image.tag=$KS_UPGRADE_TAG \
         $EXTENSION_REGISTRY_ARG \
         --set kseExtensionRepository.image.tag=$EXTENSION_VERSION \
         --set global.imageRegistry=$IMAGE_REGISTRY,global.tag=$TAG $args \
         --set upgrade.config.validator.extensionsMuseum.enabled=$([[ "$role" == "host" ]] && echo "true" || echo "false") \
         -f ks-core-values.yaml
}

function upgrade_gateway_cmd() {
    gateway_name=$1
    echo
    echo "Upgrading gateway: $gateway_name"
    echo
    kubectl -n kubesphere-system delete job dynamic-upgrade --ignore-not-found

    helm template -s templates/dynamic-upgrade-job.yaml -n kubesphere-system --release-name \
         --set upgrade.enabled=true,upgrade.dynamic=true,upgrade.config.jobs.gateway.enabled=true,upgrade.config.jobs.gateway.dynamicOptions.gatewayName=$gateway_name \
         --set global.imageRegistry=$IMAGE_REGISTRY,global.tag=$TAG,upgrade.image.tag=$KS_UPGRADE_TAG \
         $chart | kubectl -n kubesphere-system apply --wait -f -

    kubectl -n kubesphere-system wait --for=condition=complete --timeout=600s job/dynamic-upgrade
}

function upgrade_gateway() {

    confirm_image

    if [ ! -n "$gateway_name" ]; then
       echo
       # fetch all gateway names, and support switch gateway
       gateway_names=$(helm ls -Aa | grep "^kubesphere-router" | awk '{print $1}' | sed 's/-ingress$//' | sort | uniq)

       echo "Which gateway will be upgrade ? Please select the number."

       select gateway in $gateway_names; do
         gateway_name="$gateway"
         break;
       done

       echo

       # if the gateway is not empty, then confirm the upgrade
       if [[ "$gateway_name" == "" ]]; then
           echo "No gateway is selected, upgrade is aborted. Please re-run the script and select a gateway to upgrade."
           echo
           exit 1
       fi

       read -p "Please make sure gateway $gateway_name will be upgrade (yes/no): " confirm
       [[ "$confirm" != "yes" ]] && echo "upgrade cancelled" && exit 1

       echo

       count_down 5

       gateway_name=$(echo $gateway_name | tr -d '\n' | tr -d '\r' | tr -d ' ')

       upgrade_gateway_cmd $gateway_name

    else
       # confirm the upgrade
       helm ls -Aa | grep "^kubesphere-router" | awk '{print $1}' | sed 's/-ingress$//'
       echo
       echo

       if [[ "$gateway_name" == "all" ]]; then
           read -p "Please make sure all gateway will be upgrade (yes/no): " confirm
           [[ "$confirm" != "yes" ]] && echo "upgrade cancelled" && exit 1
       else
           read -p "Please make sure gateway $gateway_name will be upgrade (yes/no): " confirm
           [[ "$confirm" != "yes" ]] && echo "upgrade cancelled" && exit 1
       fi

       echo

       count_down 5

       echo

       if [[ "$gateway_name" == "all" ]]; then

           for gateway in $(helm ls -Aa | grep "^kubesphere-router" | awk '{print $1}' | sed 's/-ingress$//'); do

               upgrade_gateway_cmd $gateway

           done
       else

           upgrade_gateway_cmd $gateway_name

       fi
    fi
}

# backup
function backup() {
    timestamp=$(date +%Y%m%d-%H%M%S)
    backup_dir="backup-$timestamp"
    if [ ! -d "$backup_dir" ]; then
        mkdir "$backup_dir"
    fi

    namespaces=$(kubectl get ns -o=jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' -l kubesphere.io/workspace=system-workspace)

    namespaces+=" kubesphere-devops-worker"

    for ns in $namespaces; do

        echo "Backing up resources in namespace $ns..."

        kubectl get cm,secret,sts,deploy,ds -o yaml -n "$ns" >> "$backup_dir"/backup-"$ns".yaml

        echo "Backup for namespace $ns completed."
    done

    echo "Backup resources."

    kubectl get clusterconfigurations.installer.kubesphere.io -n kubesphere-system ks-installer -o yaml  >> "$backup_dir"/backup-cc.yaml

    kubectl get users -o yaml > "$backup_dir"/backup-iam-users.yaml
    kubectl get globalroles.iam.kubesphere.io -o yaml > "$backup_dir"/backup-iam-globalroles.yaml
    kubectl get globalrolebindings.iam.kubesphere.io -o yaml > "$backup_dir"/backup-iam-globalrolebindings.yaml
    kubectl get roles -A -o yaml > "$backup_dir"/backup-iam-roles.yaml
    kubectl get rolebindings -A -o yaml > "$backup_dir"/backup-iam-rolebindings.yaml
    kubectl get workspaceroles.iam.kubesphere.io -o yaml > "$backup_dir"/backup-iam-workspaceroles.yaml
    kubectl get workspacerolebindings.iam.kubesphere.io -o yaml > "$backup_dir"/backup-iam-workspacerolebindings.yaml
    kubectl get clusterroles -o yaml > "$backup_dir"/backup-iam-clusterroles.yaml
    kubectl get clusterrolebindings -o yaml > "$backup_dir"/backup-iam-clusterrolebindings.yaml
    kubectl get groups.iam.kubesphere.io -o yaml > "$backup_dir"/backup-iam-groups.yaml
    kubectl get groupbindings.iam.kubesphere.io -o yaml > "$backup_dir"/backup-iam-groupbindings.yaml


    kubectl get workspacetemplates.tenant.kubesphere.io -o yaml > "$backup_dir"/backup-tenant-workspacetemplates.yaml
    kubectl get workspaces.tenant.kubesphere.io -o yaml > "$backup_dir"/backup-tenant-workspaces.yaml
    kubectl get namespaces -o yaml > "$backup_dir"/backup-tenant-namespaces.yaml

    echo "Backup resources completed."
}

if [ "$role" == "host" ] || [ "$role" == "member" ]; then
    clear
    check_pending_upgrade
    echo "This cluster is about to be upgraded, and you should confirm some information before the upgrade."
    echo
    upgrade_cluster

    echo
    echo "The cluster has been upgraded."
elif [ "$role" == "gateway" ]; then
    clear
    echo "The gateway is about to be upgraded, and you should confirm some information before the upgrade."
    echo
    upgrade_gateway

    echo
    echo "The gateway has been upgraded."
fi