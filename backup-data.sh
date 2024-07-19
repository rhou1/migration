#!/bin/bash

set -x

if [[ $# -ne 5 ]]; then
  echo need chain-ca.pem file, AWS access key, AWS secret key, restic password, and deployment
  exit 1
fi

CHAIN_CA_PEM=$1
AWS_ACCESS_KEY_ID=$2
AWS_SECRET_ACCESS_KEY=$3
RESTIC_REPOSITORY=$4
RESTIC_PASSWORD=$5

# s3:https://m2-lr1-dev-vm212066.mip.storage.hpecorp.net:9000/newairflow

echo backup chain-ca.pem $CHAIN_CA_PEM AWS access key id $AWS_ACCESS_KEY_ID AWS secret access key $AWS_SECRET_ACCESS_KEY restic repository $RESTIC_REPOSITORY restic password $RESTIC_PASSWORD

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
    echo $password | sshpass scp -o StrictHostKeyChecking=no backupfiles $username@$node:/tmp/backupfiles
    echo $password | sshpass ssh -o StrictHostKeyChecking=no $username@$node sudo mv /tmp/backupfiles /mnt
    echo $password | sshpass ssh -o StrictHostKeyChecking=no $username@$node sudo chmod 777 /mnt/backupfiles
  done
}

# Function to create a backup pod for a single PVC
create_backup_pod() {
	local namespace=$1
	local pvc_name=$2

	cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: backup-$pvc_name
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
    command:
    - /bin/sh
    - -c
    - |
      # cp -p -r /mnt/chain-ca.pem .
      if restic --cacert /mnt/chain-ca.pem cat config >/dev/null 2>&1; then
        echo already initialized
      else
        echo 'not initialized'
        restic --cacert /mnt/chain-ca.pem init
      fi
      echo "init completed"
      echo in pod, deployment $deployment
      echo backupfiles
      cat /mnt/backupfiles
      restic --cacert /mnt/chain-ca.pem backup --verbose --tag "namespace=$namespace,pvc=$pvc_name,deployment=$deployment" --files-from /mnt/backupfiles
      # restic --cacert /mnt/chain-ca.pem backup /data --verbose --tag "namespace=$namespace,pvc=$pvc_name,deployment=$deployment" --files-from /mnt/backupfiles
      # restic --cacert /mnt/chain-ca.pem backup /data --verbose --tag "namespace=$namespace,pvc=$pvc_name,deployment=plat3"
      echo "Backup completed for $namespace/$pvc_name"
      restic --cacert /mnt/chain-ca.pem snapshots
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
    backup-$namespace: $namespace
EOF

	echo "Created backup pod for $namespace:$pvc_name"
}

# Get the PVC list from the ConfigMap
pvc_list=$(kubectl get configmap pvc-list -o jsonpath='{.data.pvcs}')

# Check if the ConfigMap exists and contains data
if [ -z "$pvc_list" ]; then
	echo "Error: ConfigMap 'pvc-list' not found or empty"
	exit 1
fi

# Get deployment name
deployment=$(kubectl get cm ezua-cluster-config -n ezua-system -o jsonpath='{.data.cluster\.deploymentName}')

# temporarily comment out during testing
# push_chain_ca_pem

# Process each PVC in the list
echo pvc_list $pvc_list
echo "$pvc_list" | while IFS=': ' read -r namespace pvc_info; do
        echo namespace $namespace pvc_info $pvc_info
	pvc_name=$(echo $pvc_info | cut -d' ' -f1)

	# Create the backup pod
	create_backup_pod "$namespace" "$pvc_name"
done

echo "Backup pods creation process completed"

