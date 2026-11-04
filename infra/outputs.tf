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
  value = aws_iam_role.ci.arn
}

output "errors_alarm_name" {
  value = aws_cloudwatch_metric_alarm.errors.alarm_name
}
