variable "external_network_name" {
  type        = string
  description = "Neutron external/provider network name for the demo router gateway (common default: External)."
  default     = "External"
}

variable "demo_network_name" {
  type        = string
  default     = "vpc-demo-net"
}

variable "network_name_suffix" {
  type        = string
  description = "Optional suffix for the created network name (e.g. run id) to avoid collisions with stuck/zombie Neutron objects still holding the base name."
  default     = ""
}

variable "existing_network_id" {
  type        = string
  description = "If set, do not create vpc-demo-net; use this Neutron network UUID for the subnet and Magnum fixed_network. Use when tenant network create succeeds then goes DELETED (policy, quota, or backend rejecting tenant networks)."
  default     = ""
}

variable "demo_subnet_name" {
  type        = string
  default     = "vpc-demo-subnet"
}

variable "demo_subnet_cidr" {
  type        = string
  default     = "192.168.10.0/24"
}

variable "demo_router_name" {
  type        = string
  default     = "vpc-demo-router"
}

variable "attach_to_existing_router_id" {
  type        = string
  description = "If set, skip creating a new router and attach demo_subnet to this router ID instead. Use when the external/provider network has no free IPs for new router gateways (IpAddressGenerationFailure on External). The router must already have an external gateway. Leading/trailing whitespace is trimmed (GitHub Variables sometimes add a newline)."
  default     = ""
}

variable "cluster_template_name" {
  type        = string
  description = <<-EOT
    Magnum cluster template name (public COE template in the cloud). Common examples include kubernetes-v1.26.8-rancher1 and kubernetes-v1.23.3-rancher1; they may share the same Glance image_id (e.g. Fedora CoreOS 39). Switching template names does not help if that image is missing from Glance. Discover: openstack coe cluster template list, cluster template show <name> -c image_id, openstack image list --status active.
  EOT
  default     = "kubernetes-v1.26.8-rancher1"
}

variable "cluster_name" {
  type        = string
  default     = "vpc-demo-cluster"
}

variable "master_count" {
  type        = number
  default     = 1
}

variable "node_count" {
  type        = number
  description = "Initial worker node count."
  default     = 2
}

variable "autoscaler_min_nodes" {
  type        = number
  default     = 2
}

variable "autoscaler_max_nodes" {
  type        = number
  default     = 10
}

variable "cluster_autoscaling_enabled" {
  type        = bool
  description = "When false, Magnum labels set auto_scaling_enabled=false and pin min/max nodes to node_count (demo stays fixed-size). Does not replace Keystone trust if the template still requires it (e.g. Cinder CSI); use for narrowing failures or when ops disables autoscale trust paths."
  default     = true
}

variable "dns_nameservers" {
  type        = list(string)
  default     = ["8.8.8.8"]
}
