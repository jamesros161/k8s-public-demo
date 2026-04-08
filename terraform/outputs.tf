output "cluster_id" {
  value       = openstack_containerinfra_cluster_v1.cluster.id
  description = "Magnum cluster UUID."
}

output "cluster_name" {
  value       = openstack_containerinfra_cluster_v1.cluster.name
  description = "Magnum cluster name (for openstack coe cluster config)."
}

output "demo_network_id" {
  value       = local.tenant_network_id
  description = "Tenant VPC network ID (created or pre-existing)."
}

output "demo_subnet_id" {
  value       = openstack_networking_subnet_v2.demo_subnet.id
}

output "new_router_id" {
  description = "ID of the created router when attach_to_existing_router_id is unset; null otherwise."
  value       = try(openstack_networking_router_v2.demo_router[0].id, null)
}

output "kubeconfig_hint" {
  value       = "openstack coe cluster config ${openstack_containerinfra_cluster_v1.cluster.name} --dir ~/.kube"
  description = "Command to fetch kubeconfig after the cluster reaches CREATE_COMPLETE."
}
