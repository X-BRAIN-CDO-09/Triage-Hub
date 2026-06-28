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

variable "endpoint_public_access" {
  description = "Cho phép public access vào API server endpoint. Design private-first = false. Bật true ở sandbox cho dev kubectl (nên giới hạn public_access_cidrs)."
  type        = bool
  default     = false
}

variable "public_access_cidrs" {
  description = "Danh sách CIDR được phép vào public API server endpoint (chỉ áp dụng khi endpoint_public_access = true)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "cluster_admin_arns" {
  description = "Danh sách IAM User/Role ARN được cấp quyền admin vào EKS Kubernetes API"
  type        = list(string)
  default     = []
}
