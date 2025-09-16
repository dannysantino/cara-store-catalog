# Add or update env var in .env.circleci

echo "[INFO] Setting env variables to be added to CircleCI"

set_env_var() {
  local key="$1"
  local value="$2"
  local file="deployments/.env.circleci"

  # Create file if it doesn't exist
  touch "$file"

  if grep -q "^${key}=" "$file"; then
    # Replace existing line
    sed -i.bak "s|^${key}=.*|${key}=${value}|" "$file" && rm -f "${file}.bak"
  else
    # Append new line
    echo "${key}=${value}" >> "$file"
  fi
}

set_env_var "ACCOUNT_ID" "$ACCOUNT_ID"
set_env_var "AWS_REGION" "$AWS_REGION"
set_env_var "TG_ARN" "$TG_ARN"
set_env_var "VITE_API_URL" "$VITE_API_URL"