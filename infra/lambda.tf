resource "aws_cloudwatch_log_group" "app" {
  name              = "/aws/lambda/encoder-gpt-${var.environment}"
  retention_in_days = 30
}

resource "aws_lambda_function" "app" {
  function_name = "encoder-gpt-${var.environment}"
  role          = aws_iam_role.runtime.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
  timeout       = 30
  memory_size   = 512
  publish       = true

  # Cap concurrency so a runaway client can't run up the Bedrock bill.
  reserved_concurrent_executions = 10

  tracing_config {
    mode = "Active" # X-Ray: see where latency goes (Comprehend vs. embed vs. model)
  }

  environment {
    variables = {
      MODEL_ID       = var.model_id
      EMBED_MODEL_ID = var.embed_model_id
      INDEX_BUCKET   = aws_s3_bucket.index.bucket
      INDEX_KEY      = "index/icd10_index.json"
      REDACTION_MODE = var.redaction_mode
    }
  }

  # Terraform owns the *shape* of the function; CI/CD owns *which image* runs.
  # Without this, every terraform apply would roll back the latest deploy.
  lifecycle {
    ignore_changes = [image_uri]
  }

  depends_on = [aws_cloudwatch_log_group.app]
}

# Callers always hit the "live" alias. The pipeline shifts it between
# versions for canary releases and rollback.
resource "aws_lambda_alias" "live" {
  name             = "live"
  function_name    = aws_lambda_function.app.function_name
  function_version = aws_lambda_function.app.version

  lifecycle {
    ignore_changes = [function_version, routing_config]
  }
}
