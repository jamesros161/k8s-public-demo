#!/usr/bin/env bash
set -euo pipefail

if [ -z "${GH_TOKEN:-}" ]; then
  echo "::error::GH_TOKEN is not set."
  exit 1
fi

if [ -z "${GITHUB_REPOSITORY:-}" ]; then
  echo "::error::GITHUB_REPOSITORY is not set."
  exit 1
fi

if [ -z "${KUBECONFIG_ARTIFACT_PASSPHRASE:-}" ]; then
  echo "::error::Missing KUBECONFIG_ARTIFACT_PASSPHRASE in CLOUD_ADMIN_CONFIG_B64."
  exit 1
fi

OPTIONAL_MODE="${LOAD_KUBECONFIG_ARTIFACT_OPTIONAL:-false}"

ARTIFACT_ID="$(
  gh api "repos/${GITHUB_REPOSITORY}/actions/artifacts?per_page=100" --paginate \
    --jq '.artifacts[] | select(.expired == false and (.name | startswith("kubeconfig-encrypted-"))) | "\(.created_at)\t\(.id)"' \
    | sort -r \
    | head -n1 \
    | cut -f2
)"

if [ -z "${ARTIFACT_ID}" ]; then
  if [ "${OPTIONAL_MODE}" = "true" ]; then
    echo "::notice::No non-expired kubeconfig-encrypted-* artifact found; continuing without kubeconfig."
    exit 0
  fi
  echo "::error::No non-expired kubeconfig-encrypted-* artifact found."
  exit 1
fi

ZIP_FILE="$RUNNER_TEMP/kubeconfig-artifact.zip"
EXTRACT_DIR="$RUNNER_TEMP/kubeconfig-artifact"
mkdir -p "$EXTRACT_DIR"

gh api "repos/${GITHUB_REPOSITORY}/actions/artifacts/${ARTIFACT_ID}/zip" --output "$ZIP_FILE"
unzip -o "$ZIP_FILE" -d "$EXTRACT_DIR" >/dev/null

GPG_FILE="$(ls "$EXTRACT_DIR"/*.gpg 2>/dev/null | head -n1 || true)"
if [ -z "${GPG_FILE}" ]; then
  echo "::error::Downloaded artifact does not contain a .gpg kubeconfig file."
  exit 1
fi

mkdir -p "$HOME/.kube"
printf '%s' "${KUBECONFIG_ARTIFACT_PASSPHRASE}" | gpg --batch --yes --passphrase-fd 0 --decrypt --output "$HOME/.kube/config" "$GPG_FILE"
chmod 600 "$HOME/.kube/config"
echo "KUBECONFIG=$HOME/.kube/config" >> "$GITHUB_ENV"

if ! kubectl config current-context >/dev/null 2>&1; then
  echo "::error::Decrypted kubeconfig is invalid or missing current-context."
  exit 1
fi

echo "::notice::Loaded kubeconfig from encrypted artifact id ${ARTIFACT_ID}."
