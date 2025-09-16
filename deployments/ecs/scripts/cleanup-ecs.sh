#!/bin/bash

set -euo pipefail

# Load required env vars
source deployments/ecs/scripts/export-env.sh

: "${AWS_PROFILE:?Environment variable AWS_PROFILE must be set}"

# These values should match those in the setup script

CLUSTER_NAME="carastore-cluster"
SERVICE_NAME="carastore-service"
TASK_DEF_FAMILY="carastore-server"
CONTAINER_NAME="nodejs-server"
KEY_NAME="ecs-key"
ROLE_NAME="ecsInstanceRole"
INSTANCE_PROFILE_NAME="ecsInstanceProfile"
TASK_ROLE="ecsTaskExecutionRole"
ALB_NAME="carastore-alb"
TG_NAME="carastore-tg"
ALB_SG_NAME="alb-sg"
ECS_SG_NAME="ecs-sg"
INSTANCE_TAG_NAME="carastore-ecs-instance"

echo "[INFO] Starting cleanup in region: ${AWS_REGION}"

# ECS service: set desired count to 0, then delete service
echo "[INFO] Checking for ECS service: ${SERVICE_NAME} in cluster ${CLUSTER_NAME}..."
SERVICE_DESC=$(aws ecs describe-services \
  --cluster "$CLUSTER_NAME" \
  --services "$SERVICE_NAME" \
  --region "$AWS_REGION" \
  --query 'services[0]' \
  --output json 2>/dev/null || true)

if [[ -n "$SERVICE_DESC" && "$SERVICE_DESC" != "null" ]]; then
  echo "[INFO] Setting desired count to 0 for service ${SERVICE_NAME}..."
  aws ecs update-service \
    --cluster "$CLUSTER_NAME" \
    --service "$SERVICE_NAME" \
    --desired-count 0 \
    --region "$AWS_REGION" || true

  # Wait for tasks to drain / stop (poll)
  echo "[INFO] Waiting for service tasks to stop (polling) ..."
  for i in {1..60}; do
    RUNNING_COUNT=$(aws ecs describe-services \
      --cluster "$CLUSTER_NAME" \
      --services "$SERVICE_NAME" \
      --region "$AWS_REGION" \
      --query 'services[0].runningCount' \
      --output text 2>/dev/null || echo "0")
    if [[ -z "$RUNNING_COUNT" || "$RUNNING_COUNT" == "None" || "$RUNNING_COUNT" == "0" ]]; then
      break
    fi
    sleep 5
  done

  echo "[INFO] Deleting ECS service ${SERVICE_NAME}..."
  aws ecs delete-service \
    --cluster "$CLUSTER_NAME" \
    --service "$SERVICE_NAME" \
    --force \
    --region "$AWS_REGION" || true
else
  echo "[INFO] No ECS service named ${SERVICE_NAME} found in cluster ${CLUSTER_NAME}."
fi

# Deregister task definitions (all revisions for the specified family)
echo "[INFO] Deregistering task definition revisions for family: ${TASK_DEF_FAMILY}..."
TASK_ARNS=$(aws ecs list-task-definitions \
  --family-prefix "$TASK_DEF_FAMILY" \
  --region "$AWS_REGION" \
  --query 'taskDefinitionArns' \
  --output text || true)

if [[ -n "$TASK_ARNS" && "$TASK_ARNS" != "None" ]]; then
  for TD in $TASK_ARNS; do
    echo "[INFO] Deregistering task definition: $TD"
    aws ecs deregister-task-definition \
      --task-definition "$TD" \
      --region "$AWS_REGION" || true
  done
else
  echo "[INFO] No task definitions found for family ${TASK_DEF_FAMILY}."
fi

# Drain & deregister container instances in cluster
echo "[INFO] Listing container instances in cluster ${CLUSTER_NAME}..."
CONTAINER_INSTANCES=$(aws ecs list-container-instances \
  --cluster "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --query 'containerInstanceArns' \
  --output text 2>/dev/null || true)

if [[ -n "$CONTAINER_INSTANCES" && "$CONTAINER_INSTANCES" != "None" ]]; then
  echo "[INFO] Setting container instances to DRAINING..."
  aws ecs update-container-instances-state \
    --cluster "$CLUSTER_NAME" \
    --container-instances $CONTAINER_INSTANCES \
    --status DRAINING \
    --region "$AWS_REGION" || true

  # Wait for tasks on those instances to stop (poll)
  echo "[INFO] Waiting for tasks to stop on container instances..."
  for i in {1..60}; do
    RUNNING_TASKS=$(aws ecs list-tasks \
      --cluster "$CLUSTER_NAME" \
      --region "$AWS_REGION" \
      --query 'taskArns' \
      --output text || true)
    if [[ -z "$RUNNING_TASKS" || "$RUNNING_TASKS" == "None" ]]; then
      break
    fi
    sleep 5
  done

  echo "[INFO] Deregistering container instances..."
  for CI in $CONTAINER_INSTANCES; do
    aws ecs deregister-container-instance \
      --cluster "$CLUSTER_NAME" \
      --container-instance "$CI" \
      --force \
      --region "$AWS_REGION" || true
  done
else
  echo "[INFO] No container instances found in cluster ${CLUSTER_NAME}."
fi

# Delete ECS cluster (after instances have been deregistered)
echo "[INFO] Deleting ECS cluster ${CLUSTER_NAME}..."
aws ecs delete-cluster \
  --cluster "$CLUSTER_NAME" \
  --region "$AWS_REGION" || true

# Load Balancer: delete listeners, then LB, wait for deletion, then target group
echo "[INFO] Looking up load balancer named ${ALB_NAME}..."
LB_ARN=$(aws elbv2 describe-load-balancers \
  --names "$ALB_NAME" \
  --region "$AWS_REGION" \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text 2>/dev/null || true)

if [[ -n "$LB_ARN" && "$LB_ARN" != "None" ]]; then
  echo "[INFO] Found ALB ARN: $LB_ARN"

  # Delete listeners
  echo "[INFO] Deleting listeners for ALB..."
  LISTENER_ARNS=$(aws elbv2 describe-listeners \
    --load-balancer-arn "$LB_ARN" \
    --region "$AWS_REGION" \
    --query 'Listeners[].ListenerArn' \
    --output text || true)
  for L in $LISTENER_ARNS; do
    echo "[INFO] Deleting listener $L"
    aws elbv2 delete-listener \
      --listener-arn "$L" \
      --region "$AWS_REGION" || true
  done

  # Deregister targets from target groups associated with LB
  echo "[INFO] Deleting load balancer $LB_ARN..."
  aws elbv2 delete-load-balancer \
    --load-balancer-arn "$LB_ARN" \
    --region "$AWS_REGION" || true

  # Wait for load balancer deletion
  echo "[INFO] Waiting for load balancer to be deleted..."
  for i in {1..60}; do
    EXISTS=$(aws elbv2 describe-load-balancers \
      --load-balancer-arns "$LB_ARN" \
      --region "$AWS_REGION" \
      --query 'LoadBalancers[0].LoadBalancerArn' \
      --output text 2>/dev/null || true)
    if [[ -z "$EXISTS" || "$EXISTS" == "None" ]]; then
      break
    fi
    sleep 5
  done
else
  echo "[INFO] No load balancer named ${ALB_NAME} found."
fi

# Delete target group
echo "[INFO] Looking up target group named ${TG_NAME}..."
TG_ARN=$(aws elbv2 describe-target-groups \
  --names "$TG_NAME" \
  --region "$AWS_REGION" \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text 2>/dev/null || true)
if [[ -n "$TG_ARN" && "$TG_ARN" != "None" ]]; then
  echo "[INFO] Deleting target group $TG_ARN..."
  aws elbv2 delete-target-group \
    --target-group-arn "$TG_ARN" \
    --region "$AWS_REGION" || true
else
  echo "[INFO] No target group named ${TG_NAME} found."
fi

# TLS: delete ACM cert and local files
echo "[INFO] Looking up self-signed ACM certificate..."
CERT_ARN=$(aws acm list-certificates \
  --region "$AWS_REGION" \
  --query "CertificateSummaryList[?DomainName=='carastore.local'].CertificateArn" \
  --output text 2>/dev/null || true)

if [[ -n "$CERT_ARN" && "$CERT_ARN" != "None" ]]; then
  echo "[INFO] Deleting ACM certificate: $CERT_ARN"
  aws acm delete-certificate \
    --certificate-arn "$CERT_ARN" \
    --region "$AWS_REGION" || true
else
  echo "[INFO] No ACM certificate for carastore.local found."
fi

CERT_DIR="deployments/ecs/certs"
if [[ -d "$CERT_DIR" ]]; then
  rm -f "$CERT_DIR"/certificate.crt "$CERT_DIR"/privateKey.key
  echo "[INFO] Removed local TLS certs from $CERT_DIR"
fi


# Terminate EC2 instances created by this setup
echo "[INFO] Finding EC2 instances tagged Name=${INSTANCE_TAG_NAME} ..."
INSTANCE_IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$INSTANCE_TAG_NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --region "$AWS_REGION" \
  --query 'Reservations[].Instances[].InstanceId' \
  --output text || true)

if [[ -n "$INSTANCE_IDS" && "$INSTANCE_IDS" != "None" ]]; then
  echo "[INFO] Terminating EC2 instances: $INSTANCE_IDS"
  aws ec2 terminate-instances \
    --instance-ids $INSTANCE_IDS \
    --region "$AWS_REGION" || true

  echo "[INFO] Waiting for EC2 instances to terminate..."
  aws ec2 wait instance-terminated \
    --instance-ids $INSTANCE_IDS \
    --region "$AWS_REGION" || true
else
  echo "[INFO] No EC2 instances found matching tag ${INSTANCE_TAG_NAME}."
fi

# Wait for ENIs referencing ECS security group to detach before deleting SG
echo "[INFO] Looking up security groups..."
# Find ALB SG id and ECS SG id by name
ALB_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${ALB_SG_NAME}" \
  --region "$AWS_REGION" \
  --query 'SecurityGroups[0].GroupId' \
  --output text 2>/dev/null || true)
ECS_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${ECS_SG_NAME}" \
  --region "$AWS_REGION" \
  --query 'SecurityGroups[0].GroupId' \
  --output text 2>/dev/null || true)

# Helper to ensure SG is not default before deletion
delete_sg_if_safe() {
  local SG_ID="$1"
  local SG_NAME="$2"
  if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
    echo "[INFO] Security group $SG_NAME not found; skipping."
    return
  fi

  IS_DEFAULT=$(aws ec2 describe-security-groups \
    --group-ids "$SG_ID" \
    --region "$AWS_REGION" \
    --query 'SecurityGroups[0].IsDefault' \
    --output text 2>/dev/null || true)
  if [[ "$IS_DEFAULT" == "true" ]]; then
    echo "[WARN] Security group $SG_NAME ($SG_ID) is default; will not delete."
    return
  fi

  echo "[INFO] Waiting for network interfaces attached to SG $SG_NAME ($SG_ID) to detach..."
  for i in {1..24}; do
    NIFS=$(aws ec2 describe-network-interfaces \
      --filters Name=group-id,Values="$SG_ID" \
      --region "$AWS_REGION" \
      --query 'NetworkInterfaces' \
      --output text || true)
    if [[ -z "$NIFS" || "$NIFS" == "None" ]]; then
      echo "[INFO] No ENIs attached to SG $SG_NAME; safe to delete."
      aws ec2 delete-security-group \
        --group-id "$SG_ID" \
        --region "$AWS_REGION" || true
      return
    fi
    echo "[INFO] ENIs still present for SG $SG_NAME; waiting..."
    sleep 5
  done

  echo "[WARN] Timed out waiting for ENIs to detach from SG $SG_NAME ($SG_ID). Manual cleanup may be required."
}

# Delete ECS SG then ALB SG
delete_sg_if_safe "$ECS_SG_ID" "$ECS_SG_NAME"
delete_sg_if_safe "$ALB_SG_ID" "$ALB_SG_NAME"

# Delete key pair and remove local PEM
echo "[INFO] Deleting key pair $KEY_NAME from AWS and local filesystem..."
aws ec2 delete-key-pair \
  --key-name "$KEY_NAME" \
  --region "$AWS_REGION" || true
if [[ -f "$HOME/.ssh/$KEY_NAME.pem" ]]; then
  rm -f "$HOME/.ssh/$KEY_NAME.pem" || true
  echo "[INFO] Removed local key $HOME/.ssh/$KEY_NAME.pem"
fi

# Delete Secrets Manager secret
echo "[INFO] Checking for secret: $SM_SECRET_NAME ..."
SM_ARN=$(aws secretsmanager describe-secret --secret-id "$SM_SECRET_NAME" --region "$AWS_REGION" --query 'ARN' --output text 2>/dev/null || true)
if [[ -n "$SM_ARN" && "$SM_ARN" != "None" ]]; then
  echo "[INFO] Deleting secret $SM_SECRET_NAME (scheduled deletion, 7 days by default)..."
  # You can set --recovery-window-in-days 0 to force immediate deletion
  aws secretsmanager delete-secret --secret-id "$SM_SECRET_NAME" --region "$AWS_REGION" --recovery-window-in-days 7 || true
else
  echo "[INFO] No secret named $SM_SECRET_NAME found."
fi

# Delete log groups
echo "Checking ECS log groups in region: $AWS_REGION"

LOG_GROUPS=$(aws logs describe-log-groups \
  --log-group-name-prefix "/ecs/carastore" \
  --region "$AWS_REGION" \
  --query "logGroups[].logGroupName" \
  --output text)

if [[ -z "$LOG_GROUPS" ]]; then
  echo "No /ecs/carastore log groups found in $AWS_REGION."
else
  for GROUP in $LOG_GROUPS; do
    echo "Deleting log group: $GROUP"
    aws logs delete-log-group \
      --log-group-name "$GROUP" \
      --region "$AWS_REGION"
  done
  echo "Deleted all ECS log groups in $AWS_REGION."
fi

# Cleanup IAM: task role, instance role, instance profile
echo "[INFO] Cleaning up IAM resources..."

# Task role (detach policies before deleting)
if aws iam get-role \
  --role-name "$TASK_ROLE" \
  --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "[INFO] Detaching policies from task role $TASK_ROLE..."
  aws iam detach-role-policy \
    --role-name "$TASK_ROLE" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy || true
  aws iam detach-role-policy \
    --role-name "$TASK_ROLE" \
    --policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite || true
  echo "[INFO] Deleting task role $TASK_ROLE..."
  aws iam delete-role \
    --role-name "$TASK_ROLE" \
    --region "$AWS_REGION" || true
else
  echo "[INFO] Task role $TASK_ROLE not found; skipping."
fi

# Instance profile and instance role
if aws iam get-instance-profile \
  --instance-profile-name "$INSTANCE_PROFILE_NAME" \
  --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "[INFO] Removing role from instance profile $INSTANCE_PROFILE_NAME..."
  aws iam remove-role-from-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE_NAME" \
    --role-name "$ROLE_NAME" || true
  echo "[INFO] Deleting instance profile $INSTANCE_PROFILE_NAME..."
  aws iam delete-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE_NAME" \
    --region "$AWS_REGION" || true
else
  echo "[INFO] Instance profile $INSTANCE_PROFILE_NAME not found; skipping."
fi

if aws iam get-role \
  --role-name "$ROLE_NAME" \
  --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "[INFO] Detaching policies from instance role $ROLE_NAME..."
  aws iam detach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role || true
  echo "[INFO] Deleting instance role $ROLE_NAME..."
  aws iam delete-role \
    --role-name "$ROLE_NAME" \
    --region "$AWS_REGION" || true
else
  echo "[INFO] Instance role $ROLE_NAME not found; skipping."
fi

echo "[INFO] Cleanup script finished. Certain resources (like Secrets Manager) are scheduled for deletion and may remain in recovery period."
