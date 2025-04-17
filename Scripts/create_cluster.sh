#!/bin/bash

# NOTE/WARNING:  make sure you are authenticated/authorized to the right IAM principle
#                and... kubeconfig is updated!


# UPDATE THESE VALUES
export CLUSTER_NAME="eksipv6"
export REGION="us-east-1"
export SSH_KEY_NAME="$CLUSTER_NAME-sshkey" 

# Get your accountId
export ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
# You can view your accountId from this command (I am not going to spend time adding the --query ;-)
echo "aws sts get-caller-identity"

# Display current values
echo "
CLUSTER_NAME $CLUSTER_NAME
ACCOUNT_ID $ACCOUNT_ID
REGION $REGION
SSH_KEY_NAME $SSH_KEY_NAME"

seconds=10
echo "Review values (above).  Pausing for $seconds seconds... Press CTRL-C if these are not correct"
for ((i=seconds; i>0; i--)); do
  echo -ne "$i seconds remaining...\r"
  echo 
  sleep 1
done
echo -ne "\nTime's up!\n  Moving along."

# *******************************************************************
# Create an SSH key - you probably won't actually need this, but the examples expect one
aws ec2 create-key-pair --key-name $SSH_KEY_NAME --query 'KeyMaterial' --output text > $SSH_KEY_NAME.pem
aws ec2 describe-key-pairs --region $REGION --key-names "$SSH_KEY_NAME" --query "KeyPairs[*].KeyName" --output text

# *******************************************************************
## Build your cluster (using the values from above)
cat << EOF | tee cluster.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: $CLUSTER_NAME 
  version: "1.31"
  region: $REGION

kubernetesNetworkConfig:
  ipFamily: IPv6

vpc:
  clusterEndpoints:
    publicAccess: true
    privateAccess: true

iam:
  withOIDC: true

addons:
  - name: vpc-cni
    version: latest
  - name: coredns
    version: latest
  - name: kube-proxy
    version: latest

managedNodeGroups:
  - name: m6i-xlarge-mng
    amiFamily: AmazonLinux2023
    instanceTypes: [ "m6i.xlarge", "m6a.xlarge" ]
    minSize: 1
    desiredCapacity: 2
    maxSize: 3
    volumeSize: 100
    volumeType: gp3
    volumeEncrypted: true
    ssh:
      allow: true
      publicKeyName: $SSH_KEY_NAME
    updateConfig:
      maxUnavailablePercentage: 33
EOF

# This command will not return the shell until the cluster is built
eksctl create cluster -f cluster.yaml
sleep 3

# Update your kubeconfig
aws eks update-kubeconfig --region ${REGION} --name ${CLUSTER_NAME}
kubectl get nodes

# *******************************************************************
# Add LoadBalancer Controller
# https://docs.aws.amazon.com/eks/latest/userguide/lbc-helm.html
curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.12.0/docs/install/iam_policy.json
aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://iam_policy.json

eksctl create iamserviceaccount \
    --cluster=${CLUSTER_NAME} \
    --namespace=kube-system \
    --name=aws-load-balancer-controller \
    --attach-policy-arn=arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
    --override-existing-serviceaccounts \
    --region ${REGION} \
    --approve

## TODO:  add check here to pause until CFN from last create has completed
aws cloudformation describe-stacks \
  --stack-name eksctl-${CLUSTER_NAME}-addon-iamserviceaccount-kube-system-aws-load-balancer-controller \
  --query "Stacks[0].StackStatus" \
  --output text

eksctl  get iamserviceaccount --cluster ${CLUSTER_NAME}

helm repo add eks https://aws.github.io/eks-charts
helm repo update eks
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=${CLUSTER_NAME} \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller

wget https://raw.githubusercontent.com/aws/eks-charts/master/stable/aws-load-balancer-controller/crds/crds.yaml
kubectl apply -f crds.yaml
kubectl get deployment -n kube-system aws-load-balancer-controller

## Deploy sample app
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/examples/2048/2048_full_dualstack.yaml
sleep 10
export GAME_2048=$(kubectl get ingress/ingress-2048 -n game-2048 -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo http://${GAME_2048}

aws elbv2 describe-load-balancers \
  --region ${REGION}  \
  --query "LoadBalancers[?starts_with(LoadBalancerName, 'k8s-game2048-ingress2')].[LoadBalancerName, State.Code]" \
  --output table

exit 0

## References
https://aws.amazon.com/blogs/containers/amazon-eks-launches-ipv6-support/ (a bit dated now)A
https://docs.aws.amazon.com/eks/latest/userguide/lbc-helm.html
https://docs.aws.amazon.com/eks/latest/userguide/alb-ingress.html (deploy sample app)

