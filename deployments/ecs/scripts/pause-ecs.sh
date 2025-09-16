#!/bin/bash

set -euo pipefail

# Load env vars
source deployments/ecs/scripts/export-env.sh

: "${AWS_PROFILE:?Environment variable AWS_PROFILE must be set}"

echo "[INFO] Pausing ECS resources to minimize cost..."

CLUSTER_NAME="carastore-cluster"
SERVICE_NAME="carastore-service"

echo "[INFO] Scaling service down to 0 tasks..."
aws ecs update-service \
  --cluster $CLUSTER_NAME \
  --service $SERVICE_NAME \
  --desired-count 0 || true

aws ecs wait services-stable \
  --cluster $CLUSTER_NAME \
  --services $SERVICE_NAME

echo "[INFO] Draining container instances..."
CONTAINER_INSTANCES=$(aws ecs list-container-instances \
  --cluster $CLUSTER_NAME \
  --query "containerInstanceArns[]" \
  --output text)

if [ -n "$CONTAINER_INSTANCES" ]; then
  aws ecs update-container-instances-state \
    --cluster $CLUSTER_NAME \
    --container-instances $CONTAINER_INSTANCES \
    --status DRAINING || true
fi

echo "[INFO] Stopping EC2 instances (but not terminating)..."
EC2_IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=carastore-ecs-instance" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text)

if [ -n "$EC2_IDS" ]; then
  aws ec2 stop-instances --instance-ids $EC2_IDS
  aws ec2 wait instance-stopped --instance-ids $EC2_IDS
  echo "[INFO] EC2 instances stopped: $EC2_IDS"
else
  echo "[INFO] No running ECS EC2 instances found"
fi

echo "[INFO] Pausing Load Balancer listeners (to avoid hourly + LCU charges)..."
LB_ARN=$(aws elbv2 describe-load-balancers \
  --names carastore-alb \
  --query "LoadBalancers[0].LoadBalancerArn" \
  --output text 2>/dev/null || true)

if [ -n "$LB_ARN" ]; then
  LISTENER_ARNS=$(aws elbv2 describe-listeners \
    --load-balancer-arn $LB_ARN \
    --query "Listeners[].ListenerArn" \
    --output text)

  for L in $LISTENER_ARNS; do
    aws elbv2 delete-listener --listener-arn $L || true
    echo "[INFO] Deleted listener $L"
  done
else
  echo "[INFO] No load balancer found"
fi

echo "[SUCCESS] ECS environment paused. IAM roles, SGs, and Secrets are left intact."
