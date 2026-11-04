variable "region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type    = string
  default = "dev"
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging, or prod."
  }
}

variable "image_tag" {
  description = "Initial container tag. After first deploy, the CI pipeline owns the running image."
  type        = string
  default     = "bootstrap"
}

variable "model_id" {
  description = "Bedrock model or inference profile ID. Confirm the current ID in the Bedrock console."
  type        = string
  default     = "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
}

variable "embed_model_id" {
  type    = string
  default = "amazon.titan-embed-text-v2:0"
}

variable "redaction_mode" {
  description = "basic = free pattern matching (demo only); comprehend = Comprehend Medical (Paid plan)"
  type        = string
  default     = "basic"
  validation {
    condition     = contains(["basic", "comprehend"], var.redaction_mode)
    error_message = "redaction_mode must be basic or comprehend."
  }
}

variable "github_repo" {
  description = "owner/repo allowed to assume the CI role via OIDC"
  type        = string
}

variable "alarm_email" {
  description = "Optional email for alarm notifications"
  type        = string
  default     = ""
}
