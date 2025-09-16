#!/bin/bash

set -euo pipefail

# Load required env vars
source deployments/cloud-run/scripts/export-env.sh

: "${GCP_REGION:?Environment variable GCP_REGION must be set}"
: "${BILLING_ACCOUNT_NAME:?Environment variable BILLING_ACCOUNT_NAME must be set}"

GCP_PROJECT_NAME="Cara Store"
GCP_PROJECT_ID="carastore-client-prod"
SERVICE_NAME="carastore-client"
SKIP_BILLING_LINK="false"
PORT=8080

echo "[INFO] Checking gcloud auth"
gcloud auth list \
  --filter=status:ACTIVE \
  --format="value(account)" | grep -q .
echo "[INFO] Using gcloud account: $(gcloud auth list --filter=status:ACTIVE --format='value(account)')"

echo "[INFO] Retrieving Billing Account ID"
BILLING_ACCOUNT_ID=$(gcloud billing accounts list \
  --filter="displayName='My Billing Account'" \
  --format="value(name)" | sed 's/^billingAccounts\///')
echo "Billing Account ID: $BILLING_ACCOUNT_ID"

# Create new GC project
if ! gcloud projects describe "$GCP_PROJECT_ID" >/dev/null 2>&1; then
  echo "[INFO] Creating project $GCP_PROJECT_ID"
  gcloud projects create "$GCP_PROJECT_ID" --name="$GCP_PROJECT_NAME"
else
  echo "[INFO] Project $GCP_PROJECT_ID already exists"
fi

# Link billing
if [ "$SKIP_BILLING_LINK" != "true" ]; then
  echo "[INFO] Linking billing account"
  gcloud beta billing projects link "$GCP_PROJECT_ID" \
    --billing-account "$BILLING_ACCOUNT_ID"
else
  echo "[INFO] Skipping billing link (SKIP_BILLING_LINK=true)"
fi

echo "[INFO] Setting project and region"
gcloud config set project "$GCP_PROJECT_ID" >/dev/null
gcloud config set run/region "$GCP_REGION" >/dev/null

# Enable required APIs
echo "[INFO] Enabling required APIs"
gcloud services enable \
  run.googleapis.com \
  iam.googleapis.com \
  cloudresourcemanager.googleapis.com \
  serviceusage.googleapis.com

# Create runtime service account
RUNTIME_SA_NAME="${SERVICE_NAME}-runtime"
export RUNTIME_SA_EMAIL="${RUNTIME_SA_NAME}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"

if ! gcloud iam service-accounts describe "$RUNTIME_SA_EMAIL" >/dev/null 2>&1; then
  echo "[INFO] Creating runtime service account: $RUNTIME_SA_EMAIL"
  gcloud iam service-accounts create "$RUNTIME_SA_NAME" \
    --display-name "Cloud Run runtime for ${SERVICE_NAME}"
else
  echo "[INFO] Runtime service account exists: $RUNTIME_SA_EMAIL"
fi

# Create deployer service account for CircleCI
DEPLOYER_SA_NAME="circleci-deployer"
DEPLOYER_SA_EMAIL="${DEPLOYER_SA_NAME}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"

if ! gcloud iam service-accounts describe "$DEPLOYER_SA_EMAIL" >/dev/null 2>&1; then
  echo "[INFO] Creating deployer service account: $DEPLOYER_SA_EMAIL"
  gcloud iam service-accounts create "$DEPLOYER_SA_NAME" \
    --display-name "CircleCI Cloud Run deployer"
else
  echo "[INFO] Deployer service account exists: $DEPLOYER_SA_EMAIL"
fi

echo "[INFO] Granting deployer roles"
# Project-level: can manage Cloud Run services
gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" \
  --member "serviceAccount:${DEPLOYER_SA_EMAIL}" \
  --role "roles/run.admin" >/dev/null

gcloud iam service-accounts add-iam-policy-binding "$RUNTIME_SA_EMAIL" \
  --member "serviceAccount:${DEPLOYER_SA_EMAIL}" \
  --role "roles/iam.serviceAccountUser" >/dev/null

# Create key JSON for CircleCI
KEY_FILE="deployments/cloud-run/keys/circleci-deployer-${GCP_PROJECT_ID}.json"
if [ ! -f "$KEY_FILE" ]; then
  echo "[INFO] Creating service account key: $KEY_FILE"
  mkdir -p "$(dirname "$KEY_FILE")"
  gcloud iam service-accounts keys create "$KEY_FILE" \
    --iam-account "$DEPLOYER_SA_EMAIL"
  echo "[INFO] Key saved locally to $KEY_FILE (for backup)."
  echo "  -  [ACTION REQUIRED] Copy the contents of $KEY_FILE into CircleCI project secret: GCLOUD_SERVICE_KEY"
  echo "  -  [TIP] On macOS: cat $KEY_FILE | pbcopy"
  echo "  -  [TIP] On Linux: cat $KEY_FILE | xclip -selection clipboard"
  echo "  -  [TIP] On Windows Git Bash: cat $KEY_FILE | clip"
else
  echo "[WARN] Key file already exists: $KEY_FILE (not overwriting)"
fi

# Set env variables for CircleCI
source deployments/cloud-run/scripts/set-circleci-env.sh

# URL="$(gcloud run services describe "$SERVICE_NAME" --format='value(status.url)')"
echo "[SUCCESS] Cloud Run service environment prepared:"
echo "          Service: $SERVICE_NAME"
echo "          App will be deployed via CircleCI"
