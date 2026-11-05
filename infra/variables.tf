variable "region" {
  type    = string
  default = "us-east-2"
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

variable "enable_fleet_agent" {
  description = "Run the persistent Fleet Ops Agent (always-on EC2, ~$24/mo of credits for t4g.medium)"
  type        = bool
  default     = false
}

variable "agent_channel" {
  description = "Where the agent chats and posts digests: slack, telegram, or discord. Email alerts are separate (alarm_email)."
  type        = string
  default     = "slack"
  validation {
    condition     = contains(["slack", "telegram", "discord"], var.agent_channel)
    error_message = "agent_channel must be slack, telegram, or discord."
  }
}

variable "agent_instance_type" {
  description = "Graviton instance for the agent. t4g.medium (4 GB) recommended: on t4g.small (2 GB) the OpenClaw gateway stalled under load."
  type        = string
  default     = "t4g.medium"
}

variable "lambda_reserved_concurrency" {
  description = "Max concurrent executions for the app (-1 = unreserved). Requires an account concurrency quota above 10."
  type        = number
  default     = -1
}

variable "enable_github_oidc" {
  description = "Create the GitHub OIDC provider + CI role. Blocked on AWS Free plan accounts by an org guardrail."
  type        = bool
  default     = false
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
