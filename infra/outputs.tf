output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "function_name" {
  value = aws_lambda_function.app.function_name
}

output "index_bucket" {
  value = aws_s3_bucket.index.bucket
}

output "ci_role_arn" {
  value = var.enable_github_oidc ? aws_iam_role.ci[0].arn : null
}

output "agent_instance_id" {
  value = var.enable_fleet_agent ? aws_instance.agent[0].id : null
}

output "agent_connect_command" {
  description = "Open a shell on the agent (no SSH keys, no open ports)"
  value       = var.enable_fleet_agent ? "aws ssm start-session --target ${aws_instance.agent[0].id}" : null
}

output "agent_parameter_path" {
  description = "Where to store the agent's Slack tokens (SecureString)"
  value       = local.agent_params
}

output "errors_alarm_name" {
  value = aws_cloudwatch_metric_alarm.errors.alarm_name
}
