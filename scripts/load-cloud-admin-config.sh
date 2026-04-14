#!/usr/bin/env bash
set -euo pipefail

if [ -z "${GITHUB_ENV:-}" ]; then
  echo "::error::GITHUB_ENV is not set. This script must run in GitHub Actions."
  exit 1
fi

if [ -z "${CLOUD_ADMIN_CONFIG_B64:-}" ]; then
  echo "::error::Missing secret CLOUD_ADMIN_CONFIG_B64."
  echo "::error::Set CLOUD_ADMIN_CONFIG_B64 to base64 of a KEY=VALUE env file."
  exit 1
fi

decoded_file="$(mktemp)"
echo "${CLOUD_ADMIN_CONFIG_B64}" | base64 -d > "${decoded_file}"

loaded=0
while IFS= read -r line || [ -n "${line}" ]; do
  case "${line}" in
    ""|\#*) continue ;;
  esac

  if [[ "${line}" != *=* ]]; then
    echo "::warning::Skipping invalid config line (missing '='): ${line}"
    continue
  fi

  key="${line%%=*}"
  value="${line#*=}"
  key="$(echo "${key}" | tr -d '[:space:]')"

  if [[ ! "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "::warning::Skipping invalid env key '${key}'. Use [A-Za-z0-9_]."
    continue
  fi

  delimiter="EOF_${key}_$$"
  {
    echo "${key}<<${delimiter}"
    echo "${value}"
    echo "${delimiter}"
  } >> "${GITHUB_ENV}"
  loaded=$((loaded + 1))
done < "${decoded_file}"

rm -f "${decoded_file}"
echo "::notice::Loaded ${loaded} values from CLOUD_ADMIN_CONFIG_B64 into job environment."
