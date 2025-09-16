#!/bin/bash

set -euo pipefail

# Load required env vars
source deployments/cloud-run/scripts/export-env.sh

GCP_PROJECT_ID="carastore-client-prod"
GCP_REGION="us-east1"
SERVICE_NAME="carastore-client"

: "${GCP_PROJECT_ID:?Environment variable GCP_PROJECT_ID must be set}"
: "${GCP_REGION:?Environment variable GCP_REGION must be set}"
: "${SERVICE_NAME:?Environment variable SERVICE_NAME must be set}"

# Optional: full project deletion flag (default: false)
FULL_DELETE="${FULL_DELETE:-false}"

echo "[INFO] Checking gcloud auth"
if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q .; then
  echo "[ERROR] No active gcloud account found. Run 'gcloud auth login' first."
  exit 1
fi
echo "[INFO] Using gcloud account: $(gcloud auth list --filter=status:ACTIVE --format='value(account)')"

echo "[INFO] Setting project: $GCP_PROJECT_ID"
gcloud config set project "$GCP_PROJECT_ID" >/dev/null

# ---- 1. Delete Cloud Run service ----
echo "[INFO] Deleting Cloud Run service: $SERVICE_NAME"
if gcloud run services describe "$SERVICE_NAME" --region "$GCP_REGION" >/dev/null 2>&1; then
  gcloud run services delete "$SERVICE_NAME" \
    --region "$GCP_REGION" \
    --quiet || echo "[WARN] Failed to delete Cloud Run service (already removed?)"
else
  echo "[INFO] Cloud Run service $SERVICE_NAME not found (skipping)"
fi

# ---- 2. Delete IAM service accounts ----
RUNTIME_SA_NAME="${SERVICE_NAME}-runtime"
RUNTIME_SA_EMAIL="${RUNTIME_SA_NAME}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
DEPLOYER_SA_NAME="circleci-deployer"
DEPLOYER_SA_EMAIL="${DEPLOYER_SA_NAME}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"

for SA in "$RUNTIME_SA_EMAIL" "$DEPLOYER_SA_EMAIL"; do
  if gcloud iam service-accounts describe "$SA" >/dev/null 2>&1; then
    echo "[INFO] Deleting service account: $SA"
    gcloud iam service-accounts delete "$SA" --quiet || echo "[WARN] Failed to delete $SA"
  else
    echo "[INFO] Service account $SA not found (skipping)"
  fi
done

# ---- 3. Delete IAM keys (local + remote) ----
KEY_FILE="deployments/cloud-run/keys/circleci-deployer-${GCP_PROJECT_ID}.json"
if [ -f "$KEY_FILE" ]; then
  echo "[INFO] Removing local service account key file: $KEY_FILE"
  rm -f "$KEY_FILE"
else
  echo "[INFO] No local service account key file found (skipping)"
fi

# ---- 4. Disable APIs ----
echo "[INFO] Disabling project APIs (to stop billing for unused services)"
for API in run.googleapis.com iam.googleapis.com cloudresourcemanager.googleapis.com; do
  gcloud services disable "$API" --quiet || echo "[WARN] Failed to disable API: $API"
done

# ---- 5. Final project deletion (optional) ----
if [ "$FULL_DELETE" = "true" ]; then
  echo "[ACTION] FULL_DELETE=true: Project $GCP_PROJECT_ID will be deleted."
  echo "         This removes EVERYTHING (billing stops immediately)."
  read -p "Are you sure? Type the project ID ($GCP_PROJECT_ID) to confirm: " CONFIRM
  if [ "$CONFIRM" = "$GCP_PROJECT_ID" ]; then
    gcloud projects delete "$GCP_PROJECT_ID" --quiet || echo "[ERROR] Failed to delete project"
  else
    echo "[ABORTED] Project deletion cancelled (input did not match project ID)."
  fi
else
  echo "[INFO] FULL_DELETE=false: Project $GCP_PROJECT_ID preserved."
  echo "       All Cloud Run + IAM resources have been cleaned up."
fi

echo "[SUCCESS] Clean-up completed."
