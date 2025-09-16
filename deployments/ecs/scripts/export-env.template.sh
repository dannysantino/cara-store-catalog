# Retrieve and export sensitive info for shell, task-definition.json, ecs-secrets.json

echo "[INFO] Exporting environment variables"

# shell
export AWS_PROFILE= # <==== enter your AWS profile name

# Disable AWS CLI pager so commands don't pause for input
export AWS_PAGER=""

# task-definition.json
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export AWS_REGION=$(aws configure get region)
export IMAGE_TAG=$(grep '"version":' server/package.json | head -1 | sed -E 's/.*"version": *"([^"]+)".*/\1/')
export DOCKERHUB_USERNAME= # <==== enter your Docker Hub username
export SM_SECRET_NAME=/carastore/server/env

# ecs-secrets.json
export PORT=5000
export MYSQL_HOST=mysql-db
export MYSQL_USER=carastore_admin
export MYSQL_PASSWORD= # <==== enter a user password for the DB
export MYSQL_DATABASE=carastore_catalog
export MYSQL_ROOT_PASSWORD= # <==== enter a root password for the DB