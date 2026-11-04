# ─────────────────────────────────────────────────────────────────────────────
# Fleet Ops Agent: a persistent OpenClaw agent that operates Encoder GPT.
#
# Off by default (it's always-on compute). Turn on with enable_fleet_agent = true.
# Security model: the agent's *instructions* say what it should do; this IAM
# role decides what it *can* do. Read-only everywhere, plus exactly one write:
# moving the Encoder GPT "live" alias (rollback). Prompt injection can't grant
# permissions the role doesn't have.
# ─────────────────────────────────────────────────────────────────────────────

locals {
  agent_count  = var.enable_fleet_agent ? 1 : 0
  agent_name   = "encoder-gpt-fleet-agent-${var.environment}"
  agent_params = "/encoder-gpt/${var.environment}/agent"
  function_arn = aws_lambda_function.app.arn
  live_alias   = "${aws_lambda_function.app.arn}:live"
  account_id   = data.aws_caller_identity.current.account_id
}

# Latest Amazon Linux 2023 for Graviton (arm64), resolved at plan time.
data "aws_ssm_parameter" "al2023_arm64" {
  count = local.agent_count
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

data "aws_vpc" "default" {
  count   = local.agent_count
  default = true
}

data "aws_subnets" "default" {
  count = local.agent_count
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default[0].id]
  }
}

# ── Network: no inbound at all. Admin access is Session Manager only. ───────
resource "aws_security_group" "agent" {
  count       = local.agent_count
  name        = local.agent_name
  description = "Fleet Ops Agent - no inbound; HTTPS/HTTP outbound only"
  vpc_id      = data.aws_vpc.default[0].id

  egress {
    description = "HTTPS to AWS APIs, Slack, npm"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "HTTP for OS package mirrors"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ── Identity ────────────────────────────────────────────────────────────────
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "agent" {
  count              = local.agent_count
  name               = local.agent_name
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "agent_ssm" {
  count      = local.agent_count
  role       = aws_iam_role.agent[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "agent" {
  # checkov:skip=CKV_AWS_356:Only for read APIs AWS doesn't let you scope (CloudWatch Describe/GetMetric*, Bedrock List*). Every write is resource-scoped.
  statement {
    sid = "ThinkWithBedrock"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = [
      "arn:aws:bedrock:*::foundation-model/anthropic.*",
      "arn:aws:bedrock:${var.region}:${local.account_id}:inference-profile/*",
    ]
  }

  statement {
    sid       = "DiscoverModels"
    actions   = ["bedrock:ListFoundationModels", "bedrock:ListInferenceProfiles"]
    resources = ["*"]
  }

  statement {
    sid       = "ReadAlarmsAndMetrics"
    actions   = ["cloudwatch:DescribeAlarms", "cloudwatch:DescribeAlarmHistory", "cloudwatch:GetMetricData", "cloudwatch:GetMetricStatistics"]
    resources = ["*"] # these read APIs don't support resource-level scoping
  }

  statement {
    sid       = "ReadAppLogs"
    actions   = ["logs:FilterLogEvents", "logs:GetLogEvents", "logs:DescribeLogStreams", "logs:StartLiveTail"]
    resources = [aws_cloudwatch_log_group.app.arn, "${aws_cloudwatch_log_group.app.arn}:*"]
  }

  statement {
    sid       = "InspectFunction"
    actions   = ["lambda:GetFunction", "lambda:GetFunctionConfiguration", "lambda:GetAlias", "lambda:ListVersionsByFunction", "lambda:ListAliases"]
    resources = [local.function_arn, "${local.function_arn}:*"]
  }

  statement {
    sid       = "RunEvals"
    actions   = ["lambda:InvokeFunction"]
    resources = [local.function_arn, "${local.function_arn}:*"]
  }

  # The ONE write permission: point "live" at a different version (rollback).
  statement {
    sid       = "RollbackOnly"
    actions   = ["lambda:UpdateAlias"]
    resources = [local.live_alias]
  }

  statement {
    sid       = "ReadOwnSecrets"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["arn:aws:ssm:${var.region}:${local.account_id}:parameter${local.agent_params}/*"]
  }

  # Belt and braces: even if someone widens this role later, these stay blocked.
  statement {
    sid    = "NeverAllowed"
    effect = "Deny"
    actions = [
      "lambda:UpdateFunctionCode", "lambda:UpdateFunctionConfiguration", "lambda:DeleteFunction",
      "lambda:CreateAlias", "lambda:DeleteAlias", "lambda:AddPermission",
      "iam:*", "s3:Delete*", "s3:Put*",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "agent" {
  count  = local.agent_count
  role   = aws_iam_role.agent[0].id
  policy = data.aws_iam_policy_document.agent.json
}

resource "aws_iam_instance_profile" "agent" {
  count = local.agent_count
  name  = local.agent_name
  role  = aws_iam_role.agent[0].name
}

# ── Compute ─────────────────────────────────────────────────────────────────
resource "aws_instance" "agent" {
  count                       = local.agent_count
  ami                         = data.aws_ssm_parameter.al2023_arm64[0].value
  instance_type               = var.agent_instance_type
  subnet_id                   = data.aws_subnets.default[0].ids[0]
  vpc_security_group_ids      = [aws_security_group.agent[0].id]
  iam_instance_profile        = aws_iam_instance_profile.agent[0].name
  associate_public_ip_address = true # outbound internet without a $32/mo NAT gateway; no inbound ports are open
  monitoring                  = true
  ebs_optimized               = true

  user_data = templatefile("${path.module}/../agent/bootstrap.sh.tftpl", {
    region      = var.region
    environment = var.environment
    github_repo = var.github_repo
  })
  user_data_replace_on_change = false

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
  }

  tags = {
    Name = local.agent_name
  }

  lifecycle {
    ignore_changes = [ami] # don't replace the agent (and its memory) every time AWS ships a new AMI
  }
}

# ── Self-healing: if the host fails its health checks, AWS recovers it. ─────
resource "aws_cloudwatch_metric_alarm" "agent_recover" {
  count               = local.agent_count
  alarm_name          = "${local.agent_name}-auto-recover"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  alarm_actions       = ["arn:aws:automate:${var.region}:ec2:recover", aws_sns_topic.alarms.arn]

  dimensions = {
    InstanceId = aws_instance.agent[0].id
  }
}

resource "aws_cloudwatch_metric_alarm" "agent_down" {
  count               = local.agent_count
  alarm_name          = "${local.agent_name}-instance-check"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_Instance"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  alarm_actions       = ["arn:aws:automate:${var.region}:ec2:reboot", aws_sns_topic.alarms.arn]

  dimensions = {
    InstanceId = aws_instance.agent[0].id
  }
}
