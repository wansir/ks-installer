#!/bin/bash

    cat << eof

This script will backup critical resources.

eof

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