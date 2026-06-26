variable "project_name" {
  description = "Tên dự án để gán tag và định danh tài nguyên"
  type        = string
}

variable "cluster_version" {
  description = "Phiên bản Kubernetes của EKS control plane"
  type        = string
  default     = "1.30"
}

variable "private_subnet_ids" {
  description = "Danh sách private subnet IDs để đặt control plane ENI và node group (engine private, no internet route)"
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "Cần tối thiểu 2 private subnet (multi-AZ) cho EKS."
  }
}

variable "node_instance_types" {
  description = "Instance types cho managed node group"
  type        = list(string)
  default     = ["t3.large"]
}

variable "node_scaling" {
  description = "Cấu hình scaling cho managed node group. Khớp ADR-003 / 02_infra_design.md §8.6."
  type = object({
    min_size     = optional(number, 2)
    max_size     = optional(number, 10)
    desired_size = optional(number, 2)
  })
  default = {}
}

variable "public_access_cidrs" {
  description = "List of CIDR blocks that can access the EKS public API server endpoint"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
