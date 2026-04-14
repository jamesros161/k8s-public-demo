variable "external_network_name" {
  type        = string
  description = "Neutron external/provider network name for the demo router gateway (common default: External)."
  default     = "External"
}

variable "demo_network_name" {
  type    = string
  default = "vpc-demo-net"
}

variable "network_name_suffix" {
  type        = string
  description = "Optional suffix for the created network name (e.g. run id) to avoid collisions with stuck/zombie Neutron objects still holding the base name."
  default     = ""
}

variable "existing_network_id" {
  type        = string
  description = "If set, do not create vpc-demo-net; use this Neutron network UUID for the subnet. Use when tenant network create succeeds then goes DELETED (policy, quota, or backend rejecting tenant networks)."
  default     = ""
}

variable "demo_subnet_name" {
  type    = string
  default = "vpc-demo-subnet"
}

variable "demo_subnet_cidr" {
  type    = string
  default = "192.168.10.0/24"
}

variable "demo_router_name" {
  type    = string
  default = "vpc-demo-router"
}

variable "attach_to_existing_router_id" {
  type        = string
  description = "If set, skip creating a new router and attach demo_subnet to this router ID instead. Use when the external/provider network has no free IPs for new router gateways (IpAddressGenerationFailure on External). The router must already have an external gateway. Leading/trailing whitespace is trimmed (GitHub Variables sometimes add a newline)."
  default     = ""
}

variable "cluster_name" {
  type        = string
  description = "Cluster name prefix for compute resources."
  default     = "vpc-demo-cluster"
}

variable "k8s_enabled" {
  type        = bool
  description = "When true, provision Kubernetes control-plane and worker instances with cloud-init + kubeadm."
  default     = true
}

variable "k8s_image_name" {
  type        = string
  description = "OpenStack image name for Kubernetes nodes (Ubuntu image recommended)."
  default     = ""
}

variable "k8s_flavor_name" {
  type        = string
  description = "OpenStack flavor name for Kubernetes nodes."
  default     = ""
}

variable "k8s_keypair_name" {
  type        = string
  description = "OpenStack keypair name injected into nodes for SSH access."
  default     = ""
}

variable "k8s_ssh_user" {
  type        = string
  description = "SSH username for node image."
  default     = "ubuntu"
}

variable "k8s_worker_count" {
  type        = number
  description = "Number of worker nodes to create."
  default     = 2
}

variable "k8s_worker_max_count" {
  type        = number
  description = "Target max worker count used by cluster-autoscaler defaults."
  default     = 10
}

variable "k8s_repo_channel" {
  type        = string
  description = "Kubernetes packages repository channel (example: v1.29)."
  default     = "v1.29"
}

variable "k8s_join_token" {
  type        = string
  description = "Static kubeadm bootstrap token for joining workers."
  default     = "abcdef.0123456789abcdef"
}

variable "k8s_pod_cidr" {
  type        = string
  description = "Pod CIDR passed to kubeadm init and flannel."
  default     = "10.244.0.0/16"
}

variable "k8s_ssh_allowed_cidr" {
  type        = string
  description = "CIDR allowed to SSH to cluster nodes."
  default     = "0.0.0.0/0"
}

variable "k8s_api_allowed_cidr" {
  type        = string
  description = "CIDR allowed to access Kubernetes API on control-plane."
  default     = "0.0.0.0/0"
}

variable "dns_nameservers" {
  type    = list(string)
  default = ["8.8.8.8"]
}
