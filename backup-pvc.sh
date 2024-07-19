#!/bin/bash

set -x

# Function to get PVCs for a given deployment/statefulset in a namespace
get_pvcs() {
	local resource_type=$1
	local resource_name=$2
	local namespace=$3

        local replicas=$(kubectl get statefulset $resource_name -n $namespace -o jsonpath='{.spec.replicas}')
        local volume_claims=$(kubectl get statefulset $resource_name -n $namespace -o jsonpath='{.spec.volumeClaimTemplates[*].metadata.name}')
        for (( i=0; i<$replicas; i++ ));
        do
          for claim in $volume_claims;
          do
            local pvc_name="${claim}-${resource_name}-${i}"
            local size=$(kubectl get pvc $pvc_name -n $namespace -o jsonpath='{.spec.resources.requests.storage}')
            echo "$namespace:$pvc_name $size"
          done
        done

}

# Function to add PVCs
add_pvc() {
	local pvc_name=$1
	local namespace=$2

        local size=$(kubectl get pvc $pvc_name -n $namespace -o jsonpath='{.spec.resources.requests.storage}')
        resource_pvcs="$namespace:$pvc_name $size"
        echo $resource_pvcs

	# Add PVCs to the array
	while IFS= read -r pvc; do
		[[ -n $pvc ]] && pvcs+=("$pvc")
	done <<<"$resource_pvcs"
}

# Get user input
echo "Enter deployments/statefulsets and their namespaces (format: type/name namespace), one per line. Press Ctrl+D when done:"
mapfile -t resources

# Initialize an empty array for PVCs
pvcs=()

# Process each resource
for resource in "${resources[@]}"; do
	read -r resource_type_name namespace <<<"$resource"
	IFS='/' read -r resource_type resource_name <<<"$resource_type_name"

        echo resource_type $resource_type resource_name $resource_name namespace $namespace
	# Get PVCs for the resource
	resource_pvcs=$(get_pvcs $resource_type $resource_name $namespace)

        echo resource_pvcs $resource_pvcs
	# Add PVCs to the array
	while IFS= read -r pvc; do
		[[ -n $pvc ]] && pvcs+=("$pvc")
	done <<<"$resource_pvcs"
done

# Add pvc not in statefulset
# add_pvc minio-pvc kubeflow
add_pvc volume-hpedemo-user01-a5d46626 hpedemo-user01-a5d46626

# Remove duplicates and sort PVCs
unique_pvcs=$(printf '%s\n' "${pvcs[@]}" | sort -u)

echo unique_pvcs $unique_pvcs
echo sed  "$unique_pvcs" | sed 's/^/    /'

# Create or update the ConfigMap
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: pvc-list
data:
  pvcs: |
$(echo "$unique_pvcs" | sed 's/^/    /')
EOF

echo "ConfigMap 'pvc-list' has been created or updated with the PVC list including namespaces and sizes."

