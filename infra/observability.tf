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

# Handled failures (caught exceptions -> HTTP 500) never reach Lambda's
# built-in Errors metric, so count them from the app's structured logs.
resource "aws_cloudwatch_log_metric_filter" "failures" {
  name           = "suggestion-failures"
  log_group_name = aws_cloudwatch_log_group.app.name
  pattern        = "suggestion_failed"

  metric_transformation {
    name          = "SuggestionFailures"
    namespace     = "EncoderGPT"
    value         = "1"
    default_value = "0"
  }
}

# The canary step AND the Fleet Ops Agent watch this alarm.
# Fires on crashes/timeouts (Lambda Errors) OR handled failures.
resource "aws_cloudwatch_metric_alarm" "errors" {
  alarm_name          = "encoder-gpt-${var.environment}-errors"
  evaluation_periods  = 3
  datapoints_to_alarm = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]

  metric_query {
    id          = "total"
    expression  = "FILL(crashes, 0) + FILL(handled, 0)"
    label       = "Total failures"
    return_data = true
  }

  metric_query {
    id = "crashes"
    metric {
      namespace   = "AWS/Lambda"
      metric_name = "Errors"
      period      = 60
      stat        = "Sum"
      dimensions = {
        FunctionName = aws_lambda_function.app.function_name
        Resource     = "${aws_lambda_function.app.function_name}:${aws_lambda_alias.live.name}"
      }
    }
  }

  metric_query {
    id = "handled"
    metric {
      namespace   = "EncoderGPT"
      metric_name = "SuggestionFailures"
      period      = 60
      stat        = "Sum"
    }
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
  # Text match, not a JSON pattern: Lambda prefixes each line with level,
  # timestamp, and request ID, so CloudWatch can't parse the line as JSON.
  pattern = "\"needs_review\" true" # both terms on one line = review flagged; healthy lines say false

  metric_transformation {
    name      = "NeedsHumanReview"
    namespace = "EncoderGPT"
    value     = "1"
  }
}
