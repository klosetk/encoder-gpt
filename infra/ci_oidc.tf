# GitHub Actions authenticates to AWS with short-lived OIDC tokens.
# No long-lived AWS keys stored in GitHub secrets.
#
# Optional (enable_github_oidc): AWS Free plan accounts block creating OIDC
# providers via an organization guardrail. On a Paid plan, turn this on.
resource "aws_iam_openid_connect_provider" "github" {
  count           = var.enable_github_oidc ? 1 : 0
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "ci_assume" {
  count = var.enable_github_oidc ? 1 : 0
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [one(aws_iam_openid_connect_provider.github[*].arn)]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "ci" {
  count              = var.enable_github_oidc ? 1 : 0
  name               = "encoder-gpt-ci-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.ci_assume[0].json
}

# Scoped to app deploys: push images, publish versions, move the alias,
# run evals, read the canary alarm. Infra changes (terraform apply) are run
# by a human after the PR's plan is reviewed.
data "aws_iam_policy_document" "ci" {
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage",
    ]
    resources = [aws_ecr_repository.app.arn]
  }
  statement {
    actions = [
      "lambda:UpdateFunctionCode", "lambda:PublishVersion", "lambda:GetFunction",
      "lambda:GetAlias", "lambda:UpdateAlias", "lambda:InvokeFunction",
    ]
    resources = [aws_lambda_function.app.arn, "${aws_lambda_function.app.arn}:*"]
  }
  statement {
    actions   = ["cloudwatch:DescribeAlarms"]
    resources = [aws_cloudwatch_metric_alarm.errors.arn]
  }
}

resource "aws_iam_role_policy" "ci" {
  count  = var.enable_github_oidc ? 1 : 0
  role   = aws_iam_role.ci[0].id
  policy = data.aws_iam_policy_document.ci.json
}

# Read-only so the PR pipeline can run `terraform plan` (plus state access, granted separately).
resource "aws_iam_role_policy_attachment" "ci_readonly" {
  count      = var.enable_github_oidc ? 1 : 0
  role       = aws_iam_role.ci[0].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}
