#!/bin/bash

## Prereq:  You need to create an ssh-key in the region you plan on doing this in
#              then retrieve the name of the key
export CLUSTER_NAME="spongbob"
export ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export REGION="us-east-1"
export SSH_KEY_NAME="my-ipv6-sshkey" 

# Get your accountId from this command (I am not going to spend time adding the --query ;-)
aws sts get-caller-identity

## DOUBLE CHECK THIS COMMAND REPLACES ALL THE VARS WITH THE VALUES
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

eksctl create cluster -f cluster.yaml



# Add LoadBalancer Controller
# https://docs.aws.amazon.com/eks/latest/userguide/lbc-helm.html
curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.12.0/docs/install/iam_policy.json
aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://iam_policy.json

eksctl create iamserviceaccount \
    --cluster=$CLUSTER_NAME \
    --namespace=kube-system \
    --name=aws-load-balancer-controller \
    --attach-policy-arn=arn:aws:iam::$ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy \
    --override-existing-serviceaccounts \
    --region $REGION \
    --approve

helm repo add eks https://aws.github.io/eks-charts
helm repo update eks
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller
wget https://raw.githubusercontent.com/aws/eks-charts/master/stable/aws-load-balancer-controller/crds/crds.yaml
kubectl apply -f crds.yaml
kubectl get deployment -n kube-system aws-load-balancer-controller

## Deploy sample app
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/examples/2048/2048_full_dualstack.yaml
export GAME_2048=$(kubectl get ingress/ingress-2048 -n game-2048 -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo http://${GAME_2048}

exit 0

## References
https://aws.amazon.com/blogs/containers/amazon-eks-launches-ipv6-support/ (a bit dated now)A
https://docs.aws.amazon.com/eks/latest/userguide/lbc-helm.html
https://docs.aws.amazon.com/eks/latest/userguide/alb-ingress.html (deploy sample app)

