resource "aws_sns_topic" "alarms" {
  name              = "encoder-gpt-alarms-${var.environment}"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# The canary step watches this alarm: if it fires, the pipeline rolls back.
resource "aws_cloudwatch_metric_alarm" "errors" {
  alarm_name          = "encoder-gpt-${var.environment}-errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]

  dimensions = {
    FunctionName = aws_lambda_function.app.function_name
    Resource     = "${aws_lambda_function.app.function_name}:${aws_lambda_alias.live.name}"
  }
}

resource "aws_cloudwatch_metric_alarm" "throttles" {
  alarm_name          = "encoder-gpt-${var.environment}-throttles"
  namespace           = "AWS/Lambda"
  metric_name         = "Throttles"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]

  dimensions = {
    FunctionName = aws_lambda_function.app.function_name
  }
}

# Turn the app's structured logs into a metric: how often humans must review.
resource "aws_cloudwatch_log_metric_filter" "needs_review" {
  name           = "needs-review"
  log_group_name = aws_cloudwatch_log_group.app.name
  pattern        = "{ $.event = \"suggestion\" && $.needs_review IS TRUE }"

  metric_transformation {
    name      = "NeedsHumanReview"
    namespace = "EncoderGPT"
    value     = "1"
  }
}
