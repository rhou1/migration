#!/bin/bash

set -x

. ./restore.config

echo restore chain-ca.pem $CHAIN_CA_PEM AWS access key id $AWS_ACCESS_KEY_ID AWS secret access key $AWS_SECRET_ACCESS_KEY restic password $RESTIC_PASSWORD deployment $DEPLOYMENT

remove_restore_labels() {

  nodes=$(kubectl get nodes | grep worker | awk '{print $1}')
  for node in $nodes
  do
    labels=$(kubectl get node $node -o jsonpath='{.metadata.labels}' | jq '.' | grep '\"restore' | cut -d: -f 1 | sed -e 's/"//g')
    for label in $labels
    do
      kubectl label nodes $node $label-
    done
  done
}

push_chain_ca_pem() {
  if [[ $(rpm -qa | grep sshpass | wc -l) -ne 1 ]]; then
    echo please install sshpass
    exit 1
  fi

  local password=""
  echo "Enter Username : "

  read username
  pass_var="Enter Password :"

  set +x
  # this will capture the password letter by letter
  while IFS= read -p "$pass_var" -r -s -n 1 letter
  do
      # if you press the enter key, then the loop is exited
      if [[ $letter == $'\0' ]]
      then
          break
      fi

      # the letter will be stored in password
      password=$password"$letter"

      # asterisks (*) # will printed in place of the password
      pass_var="*"
  done
  echo
  export password=$password
  set -x

  if [[ ${#username} -eq 0 ]]; then
    echo Please provide a username
    exit 1
  fi

  if [[ ${#password} -eq 0 ]]; then
    echo Please provide a password
    exit 1
  fi

  for node in $(kubectl get nodes | grep worker | awk '{print $1}')
  do
    echo node $node
    echo $password | sshpass scp -o StrictHostKeyChecking=no $CHAIN_CA_PEM $username@$node:/tmp/chain-ca.pem
    echo $password | sshpass ssh -o StrictHostKeyChecking=no $username@$node sudo mv /tmp/chain-ca.pem /mnt
    echo $password | sshpass ssh -o StrictHostKeyChecking=no $username@$node sudo chmod 777 /mnt/chain-ca.pem
  done
}

# Function to create a restore pod for a single PVC
create_restore_pod() {
	local namespace=$1
	local pvc_name=$2

        pv=$(kubectl get pvc $pvc_name -n $namespace | grep $pvc_name | awk '{print $3}')
        # user-pvc can be mounted on more than one node.  Take the first one
        node=$(kubectl get volumeattachments -n $namespace | grep $pv | awk '{print $4}' | head -1)
        # echo node $node
        if [[ ! -z $node ]]; then
          kubectl label nodes $node restore-$pvc_name=$pvc_name
        else
          kubectl label nodes $default_node restore-$pvc_name=$pvc_name
        fi

	cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: restore-$pvc_name
  namespace: $namespace
spec:
  containers:
  - name: restore-container
    image: restic/restic:latest
    env:
    - name: AWS_ACCESS_KEY_ID
      value: "$AWS_ACCESS_KEY_ID"
    - name: AWS_SECRET_ACCESS_KEY
      value: "$AWS_SECRET_ACCESS_KEY"
    - name: RESTIC_REPOSITORY
      value: $RESTIC_REPOSITORY
    - name: RESTIC_PASSWORD
      value: "$RESTIC_PASSWORD"
    volumeMounts:
    - name: data
      mountPath: /data
    - name: awsconfig-mnt
      mountPath: /mnt
    command:
    - /bin/sh
    - -c
    - |
      restic --cacert /mnt/chain-ca.pem snapshots
      echo in pod, deployment $DEPLOYMENT
      echo host $host pvc $PVC
      restic --cacert /mnt/chain-ca.pem restore --tag "namespace=$namespace,pvc=$pvc_name,deployment=$DEPLOYMENT" latest --target /
      echo "Restore completed for $namespace/$pvc_name"
      # Keep the pod running to allow for verification
      sleep infinity
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: $pvc_name
  - hostPath:
      path: /mnt
      type: DirectoryOrCreate
    name: awsconfig-mnt
  restartPolicy: Never
  nodeSelector:
    restore-$pvc_name: $pvc_name
EOF

	echo "Created restore pod for $namespace:$pvc_name"
}

# Function to create a restore pod for a single PVC
create_user_restore_pod() {
	local namespace=$1
	local pvc_name=$2

        pv=$(kubectl get pvc $pvc_name -n $namespace | grep $pvc_name | awk '{print $3}')
        # some pvc like user-pvc can be mounted on more than one node.  Take the first one
        node=$(kubectl get volumeattachments -n $namespace | grep $pv | awk '{print $4}' | head -1)
        # echo node $node
        if [[ ! -z $node ]]; then
          kubectl label nodes $node restore-$pvc_name=$pvc_name
        else
          # pvc has not been assigned to a node.
          # assign pvc to a default node, so duplicate requests are ignored
          kubectl label nodes $default_node restore-$pvc_name=$pvc_name
        fi

        # remove random characters at the end of the namespace
        # because there are different characters on the source system
        # remove random characters at the end of the pvc if the pvc begins with "volume"
        restic_namespace=$(echo $namespace | sed -e 's/\([a-z0-9-]*\)-[a-z0-9]*/\1/')
        if [[ $pvc_name == "volume"* ]]; then
          restic_pvc_name=$(echo $pvc_name | sed -e 's/\([a-z0-9-]*\)-[a-z0-9]*/\1/')
        else
          restic_pvc_name=$pvc_name
        fi
        logfile="/tmp/restore-$restic_namespace-$restic_pvc_name-$DEPLOYMENT"


	cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: restore-$pvc_name
  namespace: $namespace
spec:
  containers:
  - name: restore-container
    image: restic/restic:latest
    env:
    - name: AWS_ACCESS_KEY_ID
      value: "$AWS_ACCESS_KEY_ID"
    - name: AWS_SECRET_ACCESS_KEY
      value: "$AWS_SECRET_ACCESS_KEY"
    - name: RESTIC_REPOSITORY
      value: $RESTIC_REPOSITORY
    - name: RESTIC_PASSWORD
      value: "$RESTIC_PASSWORD"
    volumeMounts:
    - name: data
      mountPath: /data
    - name: awsconfig-mnt
      mountPath: /mnt
    - name: logdir
      mountPath: /tmp
    command:
    - /bin/sh
    - -c
    - |
      restic version
      echo restic_namespace $restic_namespace restic_pvc_name $restic_pvc_name
      restic --cacert /mnt/chain-ca.pem snapshots | tee $logfile
      echo rc $?
      echo >> $logfile
      restic --cacert /mnt/chain-ca.pem restore --tag "namespace=$restic_namespace,pvc=$restic_pvc_name,deployment=$DEPLOYMENT" latest --target / | tee -a $logfile
      echo rc $?
      echo "Restore completed for $namespace/$pvc_name"
      # Keep the pod running to allow for verification
      sleep infinity
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: $pvc_name
  - hostPath:
      path: /mnt
      type: DirectoryOrCreate
    name: awsconfig-mnt
  - hostPath:
      path: /tmp
      type: DirectoryOrCreate
    name: logdir
  restartPolicy: Never
  nodeSelector:
    restore-$pvc_name: $pvc_name
EOF

	echo "Created restore pod for $namespace:$pvc_name"
}

# Get the PVC list from the ConfigMap
pvc_list=$(kubectl get configmap pvc-list -o jsonpath='{.data.pvcs}')

# Check if the ConfigMap exists and contains data
if [ -z "$pvc_list" ]; then
	echo "Error: ConfigMap 'pvc-list' not found or empty"
	# exit 1
fi

# Get the user PVC list from the ConfigMap
user_pvc_list=$(kubectl get configmap user-pvc-list -o jsonpath='{.data.pvcs}')

# Check if the ConfigMap exists and contains data
if [[ -z "$user_pvc_list" ]]; then
        echo "ConfigMap 'user-pvc-list' not found or empty"
fi

remove_restore_labels
default_node=$(kubectl get nodes | grep worker | head -1 | awk '{print $1}')

# temporarily comment out during testing
# push_chain_ca_pem

# Process each PVC in the list
if [[ ! -z "$pvc_list" ]]; then
  echo "$pvc_list" | while IFS=': ' read -r namespace pvc_info; do
        echo namespace $namespace pvc_info $pvc_info
	pvc_name=$(echo $pvc_info | cut -d' ' -f1)
        host="backup-$pvc_name"

	# Create the restore pod
	create_restore_pod "$namespace" "$pvc_name"
  done
fi

# Process each user PVC in the list
if [[ ! -z "$user_pvc_list" ]]; then
  # echo user_pvc_list $user_pvc_list
  echo "$user_pvc_list" | while IFS=': ' read -r namespace pvc_info; do
        pvc_name=$(echo $pvc_info | cut -d' ' -f1)

        # Create the restore pod
        create_user_restore_pod "$namespace" "$pvc_name"
        sleep 10
  done
fi

echo "Restore pods creation process completed"
