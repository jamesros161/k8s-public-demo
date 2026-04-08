#!/usr/bin/env bash
# Print a Kubernetes/Helm-safe site slug: lowercase DNS label (RFC 1123).
# Usage: normalize-site-id.sh <raw_site_id>
# Exits non-zero if the normalized value is not a valid label (max 63 chars).
set -euo pipefail

RAW="${1:?site id required}"

SLUG=$(printf '%s' "$RAW" | tr '[:upper:]' '[:lower:]')

if ! [[ "${SLUG}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || [ "${#SLUG}" -gt 63 ]; then
  echo "site_id must be a DNS label (letters, digits, hyphens; max 63 chars). Got '${RAW}' -> '${SLUG}' (invalid)." >&2
  exit 1
fi

if [ "${RAW}" != "${SLUG}" ]; then
  echo "Normalized site_id for Kubernetes/Helm: '${RAW}' -> '${SLUG}'" >&2
fi

printf '%s\n' "${SLUG}"
