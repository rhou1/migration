#!/bin/bash

# set -x

. ./backup.config

echo backup chain-ca.pem $CHAIN_CA_PEM AWS access key id $AWS_ACCESS_KEY_ID AWS secret access key $AWS_SECRET_ACCESS_KEY restic repository $RESTIC_REPOSITORY restic password $RESTIC_PASSWORD

remove_backup_labels() {

  nodes=$(kubectl get nodes | grep worker | awk '{print $1}')
  for node in $nodes
  do
    labels=$(kubectl get node $node -o jsonpath='{.metadata.labels}' | jq '.' | grep '\"hpe.com/backup' | cut -d: -f 1 | sed -e 's/"//g')
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

# Function to create a backup pod for a single PVC
create_backup_pod() {
	local namespace=$1
	local pvc_name=$2

        pv=$(kubectl get pvc $pvc_name -n $namespace | grep $pvc_name | awk '{print $3}')
        # user-pvc can be mounted on more than one node.  Take the first one
        node=$(kubectl get volumeattachments -n $namespace | grep $pv | awk '{print $4}' | head -1)
        if [[ ! -z $node ]]; then
          kubectl label nodes $node hpe.com/backup-$pvc_name=$pvc_name
        else
          kubectl label nodes $default_node hpe.com/backup-$pvc_name=$pvc_name
        fi
        logfile="/tmp/backup-$namespace-$pvc_name-$DEPLOYMENT"

	cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: hpe-backup-$pvc_name
  namespace: $namespace
  labels:
    app: backup
spec:
  containers:
  - name: backup-container
    image: restic/restic:latest
    env:
    - name: AWS_ACCESS_KEY_ID
      value: "$AWS_ACCESS_KEY_ID"
    - name: AWS_SECRET_ACCESS_KEY
      value: "$AWS_SECRET_ACCESS_KEY"
    - name: RESTIC_REPOSITORY
      value: $RESTIC_REPOSITORY
    - name: RESTIC_PASSWORD
      value: $RESTIC_PASSWORD
    volumeMounts:
    - name: data
      mountPath: /data
    - name: awsconfig-mnt
      mountPath: /mnt
    resources:
      requests:
        memory: 1Gi
        cpu: 100m
      limits:
        memory: 1Gi
        cpu: 300m
    command:
    - /bin/sh
    - -c
    - |
      echo "start pod"
      if restic --cacert /mnt/chain-ca.pem cat config >/dev/null 2>&1; then
        echo already initialized
      else
        echo 'not initialized'
        restic --cacert /mnt/chain-ca.pem init
      fi
      echo "init completed"
      restic --cacert /mnt/chain-ca.pem backup /data --verbose --tag "namespace=$namespace,pvc=$pvc_name,deployment=$deployment" | tee $logfile
      echo "Backup completed for $namespace/$pvc_name"
      restic --cacert /mnt/chain-ca.pem snapshots | tee -a $logfile
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
    hpe.com/backup-$pvc_name: $pvc_name
EOF

	echo "Created backup pod for $namespace:$pvc_name"
}

# Function to create a backup pod for a single PVC
create_user_backup_pod() {
	local namespace=$1
	local pvc_name=$2

        pv=$(kubectl get pvc $pvc_name -n $namespace | grep $pvc_name | awk '{print $3}')
        # some pvc like user-pvc can be mounted on more than one node.  Take the first one
        node=$(kubectl get volumeattachments -n $namespace | grep $pv | awk '{print $4}' | head -1)
        if [[ ! -z $node ]]; then
          kubectl label nodes $node hpe.com/backup-$pvc_name=$pvc_name
        else
          # pvc has not been assigned to a node.
          # assign pvc to a default node, so duplicate requests are ignored
          kubectl label nodes $default_node hpe.com/backup-$pvc_name=$pvc_name
        fi

        # remove random characters at the end of the namespace
        # because there will be different characters on the target system
        # remove random characters at the end of the pvc if the pvc begins with "volume"
        restic_namespace=$(echo $namespace | sed -e 's/\([a-z0-9-]*\)-[a-z0-9]*/\1/')
        if [[ $pvc_name == "volume"* ]]; then
          restic_pvc_name=$(echo $pvc_name | sed -e 's/\([a-z0-9-]*\)-[a-z0-9]*/\1/')
        else
          restic_pvc_name=$pvc_name
        fi

        logfile="/tmp/backup-$restic_namespace-$restic_pvc_name-$DEPLOYMENT"

	cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: hpe-backup-$pvc_name
  namespace: $namespace
  labels:
    app: backup
spec:
  containers:
  - name: backup-container
    image: restic/restic:latest
    env:
    - name: AWS_ACCESS_KEY_ID
      value: "$AWS_ACCESS_KEY_ID"
    - name: AWS_SECRET_ACCESS_KEY
      value: "$AWS_SECRET_ACCESS_KEY"
    - name: RESTIC_REPOSITORY
      value: $RESTIC_REPOSITORY
    - name: RESTIC_PASSWORD
      value: $RESTIC_PASSWORD
    volumeMounts:
    - name: data
      mountPath: /data
    - name: awsconfig-mnt
      mountPath: /mnt
    resources:
      requests:
        memory: 1Gi
        cpu: 100m
      limits:
        memory: 1Gi
        cpu: 300m
    command:
    - /bin/sh
    - -c
    - |
      if restic --cacert /mnt/chain-ca.pem cat config >/dev/null 2>&1; then
        echo already initialized
      else
        echo 'not initialized'
        restic --cacert /mnt/chain-ca.pem init
      fi
      echo "init completed"
      restic --cacert /mnt/chain-ca.pem backup /data --verbose --tag "namespace=$restic_namespace,pvc=$restic_pvc_name,deployment=$deployment" --exclude "/data/$restic_namespace/$restic_namespace-*"
      echo restic rc $?
      echo "Backup completed for $namespace/$pvc_name"
      restic --cacert /mnt/chain-ca.pem snapshots
      echo restic rc $?
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
    hpe.com/backup-$pvc_name: $pvc_name
EOF

	echo "Created backup pod for $namespace:$pvc_name"
}

# Get the PVC list from the ConfigMap
pvc_list=$(kubectl get configmap pvc-list -o jsonpath='{.data.pvcs}')

# Check if the ConfigMap exists and contains data
if [[ -z "$pvc_list" ]]; then
	echo "ConfigMap 'pvc-list' not found or empty"
fi

# Get the user PVC list from the ConfigMap
user_pvc_list=$(kubectl get configmap user-pvc-list -o jsonpath='{.data.pvcs}')

# Check if the ConfigMap exists and contains data
if [[ -z "$user_pvc_list" ]]; then
	echo "ConfigMap 'user-pvc-list' not found or empty"
fi

remove_backup_labels
default_node=$(kubectl get nodes | grep worker | head -1 | awk '{print $1}')

# Get deployment name
deployment=$(kubectl get cm ezua-cluster-config -n ezua-system -o jsonpath='{.data.cluster\.deploymentName}')

# temporarily comment out during testing
# push_chain_ca_pem

# Process each PVC in the list
if [[ ! -z "$pvc_list" ]]; then
  echo "$pvc_list" | while IFS=': ' read -r namespace pvc_info; do
	pvc_name=$(echo $pvc_info | cut -d' ' -f1)

	# Create the backup pod
	create_backup_pod "$namespace" "$pvc_name"
        sleep 10
  done
fi

# Process each user PVC in the list
if [[ ! -z "$user_pvc_list" ]]; then
  echo "$user_pvc_list" | while IFS=': ' read -r namespace pvc_info; do
	pvc_name=$(echo $pvc_info | cut -d' ' -f1)

	# Create the backup pod
	create_user_backup_pod "$namespace" "$pvc_name"
        sleep 10
  done
fi

echo "Backup pods creation process completed"

