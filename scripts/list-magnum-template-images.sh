#!/usr/bin/env bash
# Cross-check Magnum cluster templates against Glance: prints template name, image_id, flavor_id.
# Requires: OpenStack CLI + Magnum plugin, authenticated project (same as Terraform/CI).
set -euo pipefail

echo "=== Cluster templates (name, image_id, flavor_id) ==="
while IFS= read -r name; do
  [[ -z "${name// }" ]] && continue
  img=$(openstack coe cluster template show "$name" -c image_id -f value 2>/dev/null || echo "(show failed)")
  flv=$(openstack coe cluster template show "$name" -c flavor_id -f value 2>/dev/null || echo "?")
  printf '%s\n  image_id=%s\n  flavor_id=%s\n' "$name" "$img" "$flv"
done < <(openstack coe cluster template list -c name -f value)

echo ""
echo "=== Glance images (active) ==="
openstack image list --status active -c Name -f value | sort -u

echo ""
echo "Tip: any template whose image_id matches a Name above (exact string) is a good candidate for CLUSTER_TEMPLATE_NAME."
