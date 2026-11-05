# ─────────────────────────────────────────────────────────────────────────────
# Slack /encode: lets coders send a description from Slack and get codes back.
#
# Off by default (enable_slack_command). Each use is one Bedrock call, so it
# only runs when someone in YOUR Slack workspace types the command: requests
# without a valid Slack signature are rejected before any model call.
# API Gateway, Lambda, and logs stay inside the free tier at demo volume.
# ─────────────────────────────────────────────────────────────────────────────

locals {
  slack_count        = var.enable_slack_command ? 1 : 0
  slack_name         = "encoder-gpt-slack-${var.environment}"
  slack_secret_param = "/encoder-gpt/${var.environment}/slack/signing-secret"
  slack_fn_arn       = "arn:aws:lambda:${var.region}:${local.account_id}:function:${local.slack_name}"
}

data "archive_file" "slack" {
  type        = "zip"
  source_file = "${path.module}/../gateway/handler.py"
  output_path = "${path.module}/.build/slack-gateway.zip"
}

resource "aws_cloudwatch_log_group" "slack" {
  count             = local.slack_count
  name              = "/aws/lambda/${local.slack_name}"
  retention_in_days = 30
}

resource "aws_iam_role" "slack" {
  count              = local.slack_count
  name               = local.slack_name
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "slack" {
  count = local.slack_count

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.slack[0].arn}:*"]
  }

  # Call only the live alias (never $LATEST or a pinned version), plus itself for the async pass.
  statement {
    sid       = "CallEncoder"
    actions   = ["lambda:InvokeFunction"]
    resources = [local.live_alias, local.slack_fn_arn]
  }

  statement {
    sid       = "ReadSigningSecret"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${var.region}:${local.account_id}:parameter${local.slack_secret_param}"]
  }

  statement {
    sid       = "Tracing"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"] # X-Ray write APIs don't support resource scoping
  }
}

resource "aws_iam_role_policy" "slack" {
  count  = local.slack_count
  role   = aws_iam_role.slack[0].id
  policy = data.aws_iam_policy_document.slack[0].json
}

resource "aws_lambda_function" "slack" {
  # checkov:skip=CKV_AWS_272:Code signing isn't needed for a single-file zip built from this repo.
  count            = local.slack_count
  function_name    = local.slack_name
  role             = aws_iam_role.slack[0].arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.slack.output_path
  source_code_hash = data.archive_file.slack.output_base64sha256
  timeout          = 30
  memory_size      = 256

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      ENCODER_FUNCTION   = local.live_alias
      SLACK_SECRET_PARAM = local.slack_secret_param
      MAX_CHARS          = "1000"
    }
  }

  depends_on = [aws_cloudwatch_log_group.slack]
}

# The async pass posts to Slack; a retry would post the answer twice.
resource "aws_lambda_function_event_invoke_config" "slack" {
  count                  = local.slack_count
  function_name          = aws_lambda_function.slack[0].function_name
  maximum_retry_attempts = 0
}

# ── Public HTTPS endpoint Slack calls (the only thing it accepts is POST /slack) ──
resource "aws_apigatewayv2_api" "slack" {
  count         = local.slack_count
  name          = local.slack_name
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "slack" {
  count                  = local.slack_count
  api_id                 = aws_apigatewayv2_api.slack[0].id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.slack[0].invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "slack" {
  count     = local.slack_count
  api_id    = aws_apigatewayv2_api.slack[0].id
  route_key = "POST /slack"
  target    = "integrations/${aws_apigatewayv2_integration.slack[0].id}"
}

resource "aws_cloudwatch_log_group" "slack_access" {
  count             = local.slack_count
  name              = "/aws/apigateway/${local.slack_name}"
  retention_in_days = 30
}

resource "aws_apigatewayv2_stage" "slack" {
  count       = local.slack_count
  api_id      = aws_apigatewayv2_api.slack[0].id
  name        = "$default"
  auto_deploy = true

  # Hard ceiling on request rate, so even a flood of junk can't pile up.
  default_route_settings {
    throttling_burst_limit = 5
    throttling_rate_limit  = 1
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.slack_access[0].arn
    format = jsonencode({
      requestId = "$context.requestId"
      ip        = "$context.identity.sourceIp"
      route     = "$context.routeKey"
      status    = "$context.status"
      latencyMs = "$context.responseLatency"
    })
  }
}

resource "aws_lambda_permission" "slack_apigw" {
  count         = local.slack_count
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.slack[0].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.slack[0].execution_arn}/*/*/slack"
}

resource "aws_cloudwatch_metric_alarm" "slack_errors" {
  count               = local.slack_count
  alarm_name          = "${local.slack_name}-errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  dimensions          = { FunctionName = aws_lambda_function.slack[0].function_name }
}
