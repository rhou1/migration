#!/bin/bash

set -x

# Function to create a PVC
create_pvc() {
	local namespace=$1
	local pvc_name=$2
	local size=$3
	local storage_class="standard" # Change this to your desired storage class

	cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $pvc_name
  namespace: $namespace
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: $size
EOF

	echo "Created PVC '$pvc_name' in namespace '$namespace' with size '$size'"
}

# Get the PVC list from the ConfigMap
pvc_list=$(kubectl get configmap pvc-list -o jsonpath='{.data.pvcs}')

# Check if the ConfigMap exists and contains data
if [ -z "$pvc_list" ]; then
	echo "Error: ConfigMap 'pvc-list' not found or empty"
	exit 1
fi

# Process each PVC in the list
echo "$pvc_list" | while IFS=': ' read -r namespace pvc_info; do
	pvc_name=$(echo $pvc_info | cut -d' ' -f1)
	pvc_size=$(echo $pvc_info | cut -d' ' -f2)

        echo pvc_name $pvc_name pvc_size $pvc_size

	# Check if namespace exists, create if it doesn't
	if ! kubectl get namespace "$namespace" &>/dev/null; then
		kubectl create namespace "$namespace"
		echo "Created namespace '$namespace'"
	fi

	# Create the PVC
        echo namespace $namespace
	create_pvc "$namespace" "$pvc_name" "$pvc_size"
done

echo "PVC creation process completed"
