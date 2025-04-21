#!/bin/bash
##############################################################################################
# Script to check the health status of the cluster and check critical cases for ks-upgrade   #
##############################################################################################


# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PLAIN='\033[0m'
bold=$(tput bold)
normal=$(tput sgr0)

function cluster_objects() {
  namespace=$1
  if [[ "$namespace" == '-A' ]]; then
    echo -e "Collecting Information from the Cluster:"
  else
    n=$(echo $namespace | awk {'print $2'})
    echo -e "Collecting Information from the namespace $n:"
  fi

	deployments=$(kubectl get deployment $namespace --ignore-not-found | grep -v NAMESPACE | wc -l)
	pods=$(kubectl get po $namespace --ignore-not-found | grep -v NAMESPACE | wc -l)
	services=$(kubectl get svc $namespace --ignore-not-found | grep -v NAMESPACE | wc -l)
  ingresses=$(kubectl get ing $namespace --ignore-not-found | grep -v NAMESPACE | wc -l)
	statefulset=$(kubectl get statefulset $namespace --ignore-not-found | grep -v NAMESPACE | wc -l)
	daemonset=$(kubectl get daemonset $namespace --ignore-not-found | grep -v NAMESPACE | wc -l)
	replicaset=$(kubectl get rs $namespace --ignore-not-found | grep -v NAMESPACE | wc -l)
	serviceaccount=$(kubectl get sa $namespace --ignore-not-found | grep -v NAMESPACE | wc -l)
	storageclass=$(kubectl get sc $namespace --ignore-not-found | grep -v NAMESPACE | wc -l)
	PodDistrubtion=$(kubectl get pdb $namespace --ignore-not-found | grep -v NAMESPACE | wc -l)
	CustomResources=$(kubectl get crd $namespace --ignore-not-found | grep -v NAMESPACE | wc -l)
	cronjobs=$(kubectl get cronjobs $namespace --ignore-not-found | grep -v NAMESPACE | wc -l)
	persistentvolumes=$(kubectl get pv $namespace --ignore-not-found | grep -v NAMESPACE | wc -l)
	persistentvolumeclaims=$(kubectl get pvc $namespace --ignore-not-found | grep -v NAMESPACE | wc -l)
	hpa=$(kubectl get hpa $namespace --ignore-not-found | grep -v NAMESPACE | wc -l)

	if [[ "$namespace" == '-A' ]]; then
    echo -e "Cluster Resources:"
  else
    n=$(echo $namespace | awk {'print $2'})
    echo -e "$n Resources:"
  fi


	echo -e "${BLUE}"Deployments"                    :${GREEN}$deployments"
	echo -e "${BLUE}"Services"                       :${GREEN}$services"
	echo -e "${BLUE}"Ingresses"                      :${GREEN}$ingresses"
	echo -e "${BLUE}"StatefulSets"                   :${GREEN}$statefulset"
	echo -e "${BLUE}"Pods"                           :${GREEN}$pods"
	echo -e "${BLUE}"DaemonSets"                     :${GREEN}$daemonset"
	echo -e "${BLUE}"ReplicaSets"                    :${GREEN}$replicaset"
	echo -e "${BLUE}"StorageClasses"                 :${GREEN}$storageclass"
	echo -e "${BLUE}"CronJobs"                       :${GREEN}$cronjobs"
	echo -e "${BLUE}"CustomResources"                :${GREEN}$CustomResources"
	echo -e "${BLUE}"HorizontalPodAutoscaler"        :${GREEN}$hpa"
	echo -e "${BLUE}"PersistentVolumes"              :${GREEN}$persistentvolumes"
	echo -e "${BLUE}"PersistentVolumeClaims"         :${GREEN}$persistentvolumeclaims"
  echo
}

function cluster_nodes() {
  kubectl get nodes -o=custom-columns=NAME:.metadata.name,STATUS:.status.conditions[-1].type,VERSION:.status.nodeInfo.kubeletVersion,OS:.status.nodeInfo.osImage,CONTAINER-RUNTIME:.status.nodeInfo.containerRuntimeVersion
	nodes=$(kubectl get nodes | grep -v NAME | wc -l)
	worker=$(kubectl get nodes | grep -v NAME | grep worker | wc -l)
	master=$(kubectl get nodes | grep -v NAME | grep master | wc -l)
	node_status=$(for i in $(kubectl get node | grep -v NAME | awk {'print $2'} | sort -u); do echo "$i";done)
	echo
  echo -e "Cluster Node Status:"
	echo -e "${BLUE}"ALL Nodes"                      :${GREEN}$nodes"
	echo -e "${BLUE}"Worker Nodes"                   :${GREEN}$worker"
	echo -e "${BLUE}"Master Nodes"                   :${GREEN}$master"
	echo -e "${BLUE}"Nodes Status"                   :${GREEN}$node_status"
	echo
  echo -e "Conditions Per Node:"
  for node in $(kubectl get node | grep -v NAME | awk {'print $1'}); do
    echo -e "${BLUE}"$node" :"
    echo -e "${BLUE}$(kubectl describe node $node | grep kubelet | awk {'print $15'} | sort -u)"
	done
	echo
	echo -e "Pods Per Node:"
  for node in $(kubectl get node | grep -v NAME | awk {'print $1'}); do
    pod_per_node=$(kubectl get pods --all-namespaces --field-selector spec.nodeName=$node -o wide | wc -l)
	  echo -e "${BLUE}"$node" \t :${GREEN}$pod_per_node"
	done
  echo -e "\033[0m"
	echo
}

# 状态异常的 Pod
function pod_with_issues() {
	echo -e "Pods not in Running or Completed State:"
  kubectl get pods --all-namespaces --field-selector=status.phase!=Running --ignore-not-found | grep -v Completed
  echo
	}

# KubeSphere 信息
function kubesphere_info() {
  echo -e "KubeSphere Info:"
  echo "version (This is \`metadata.labels.version\` in cc):"

  cluster_configuration=$(kubectl api-resources | grep ClusterConfiguration | wc -l)
  if [ $cluster_configuration -eq 0 ]; then
    echo
    echo "    ❌ No ClusterConfiguration (cc) found, this cluster can't be upgraded !"
    echo
  else
    ks_installer_cc=$(kubectl get cc -n kubesphere-system ks-installer --no-headers --ignore-not-found | wc -l)
    if [ $ks_installer_cc -eq 0 ]; then
      echo
      echo "    ❌ No ClusterConfiguration (cc) found, this cluster can't be upgraded !"
      echo
    else
      kubectl get cc ks-installer -n kubesphere-system -o jsonpath='{.metadata.labels.version}'
      echo
      echo "components status in cc:"
      kubectl describe  cc -n kubesphere-system ks-installer | awk '/Status:/{flag=1} flag && /^ /'
    fi
  fi
}

function kubesphere_cluster_info() {
  echo -e "KubeSphere Cluster Info:"
  echo
  kubectl get cluster.cluster.kubesphere.io --no-headers
  echo
}

function version_compare() {
  current_version=$(echo $1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  target_version=$(echo $2 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')

  current_version_array=(${current_version//./ })
  target_version_array=(${target_version//./ })
  for i in 0 1 2; do
    if [ ${current_version_array[$i]} -lt ${target_version_array[$i]} ]; then
      return 0
    elif [ ${current_version_array[$i]} -gt ${target_version_array[$i]} ]; then
      return 2
    fi
  done
  return 1
}

function node_status_check() {
  echo
  echo -e "NotReady Node Check:"
  echo
  notReadyCount=0
  node_status=$(kubectl get nodes | grep -v NAME | awk {'print $2'} | sort -u)
  for status in $node_status; do
    if [ "$status" != "Ready" ]; then
      echo "    ❌ Node status has NotReady, please check node status in cluster !"
      notReadyCount=$((notReadyCount + 1))
    fi
  done
  if [ $notReadyCount -eq 0 ]; then
    echo "    ✅ All nodes are Ready"
  fi
}

function default_storageclass_check() {
  echo
  echo -e "Default Storageclass Check:"
  echo
  default_storageclass=$(kubectl get sc | grep '(default)' | wc -l)
  if [ $default_storageclass -eq 0 ]; then
    echo "    ❌ No default storageclass found, please check storageclass in cluster !"
  else
    echo "    ✅ Found default storageclass in cluster"
  fi
}

function kubernetes_version_check() {
  echo
  echo -e "Kubernetes Version Check:"
  echo
  min_version="v1.21.0"
  # get kubernetes version
  kubernetes_version=$(kubectl version | grep 'Server Version' | awk '{print $3}')

  version_compare $kubernetes_version $min_version
  if [ $? -eq 0 ]; then
    echo "    ❌ Kubernetes version $kubernetes_version is less than minimal version $min_version"
  else
    echo "    ✅ Kubernetes version $kubernetes_version is not less than minimal version $min_version"
  fi
}


function helm_version_check() {
  echo
  echo -e "Helm Version Check:"
  echo
  min_version="v3.13.0"
  # get helm version
  helm_version=$(helm version --short)
  version_compare $helm_version $min_version
  if [ $? -eq 0 ]; then
    echo "    ❌ Helm version $helm_version is less than minimal version $min_version"
  else
    echo "    ✅ Helm version $helm_version is not less than minimal version $min_version"
  fi
}

function kubesphere_version_check() {
  echo
  echo -e "KubeSphere Version Check:"
  echo
  min_version="v3.4.0"

  cluster_configuration=$(kubectl api-resources | grep ClusterConfiguration | wc -l)
  if [ $cluster_configuration -eq 0 ]; then
    echo "    ❌ No ClusterConfiguration (cc) found, this cluster can't be upgraded !"
  else
    ks_installer_cc=$(kubectl get cc -n kubesphere-system ks-installer --no-headers --ignore-not-found | wc -l)
    if [ $ks_installer_cc -eq 0 ]; then
      echo "    ❌ No ClusterConfiguration (cc) found, this cluster can't be upgraded !"
    else
      # get kubesphere version
      kubesphere_version=$(kubectl get cc ks-installer -n kubesphere-system -o jsonpath='{.metadata.labels.version}')
      version_compare $kubesphere_version $min_version
      if [ $? -eq 0 ]; then
        echo "    ❌ KubeSphere version $kubesphere_version is less than minimal version $min_version"
      else
        echo "    ✅ KubeSphere version $kubesphere_version is not less than minimal version $min_version"
      fi
    fi
  fi
}

function ks_installer_logs_check() {
  echo
  echo -e "ks-installer Logs Check:"
  echo
  ks_installer_pod=$(kubectl get pod --no-headers --ignore-not-found -n kubesphere-system -l 'app in (ks-install, ks-installer)' | wc -l)
  if [ $ks_installer_pod -eq 0 ]; then
    echo "    ✅ There are no tasks running in ks-installer."
  else
    logs=$(kubectl logs -n kubesphere-system $(kubectl get pod -n kubesphere-system -l 'app in (ks-install, ks-installer)' -o jsonpath='{.items[0].metadata.name}') --tail=20)
    if [[ $logs =~ "Welcome to KubeSphere!" ]]; then
      echo "    ✅ There are no tasks running in ks-installer."
    else
      echo "    ❌ There are tasks running in ks-installer. Please use the following command to check the ks-installer command."
      echo
      echo "            kubectl get pod -n kubesphere-system -l 'app in (ks-install, ks-installer)' -o jsonpath='{.items[0].metadata.name}')"
      echo
    fi
  fi
}

clear
if ! command -v kubectl &> /dev/null; then
  echo "kubectl could not be found"
  exit
fi
if ! command -v helm &> /dev/null; then
  echo "helm could not be found"
  exit
fi
if ! command -v jq &> /dev/null; then
  echo "jq could not be found"
  exit
fi

cluster_objects -A
cluster_nodes
pod_with_issues
kubesphere_info
kubesphere_cluster_info
node_status_check
default_storageclass_check
kubernetes_version_check
helm_version_check
kubesphere_version_check
ks_installer_logs_check
echo





