terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  backend "s3" {
    bucket         = "tfstate-serverless-api-prod"
    key            = "prod/terraform.tfstate"
    region         = "ap-northeast-1"
    encrypt        = true
    dynamodb_table = "tfstate-lock"
  }
}

provider "aws" {
  region = var.aws_region
  default_tags { tags = { Project = var.project, Env = var.env } }
}

# ── DynamoDB ──────────────────────────────────────────────
resource "aws_dynamodb_table" "main" {
  name         = "${var.project}-${var.env}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute { name = "pk";    type = "S" }
  attribute { name = "sk";    type = "S" }
  attribute { name = "email"; type = "S" }

  global_secondary_index {
    name            = "email-index"
    hash_key        = "email"
    projection_type = "ALL"
  }

  point_in_time_recovery { enabled = true }
  server_side_encryption { enabled = true }

  lifecycle { prevent_destroy = true }
}

# ── CloudWatch Log Group ──────────────────────────────────
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.project}-${var.env}"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "apigw" {
  name              = "/aws/apigateway/${var.project}-${var.env}"
  retention_in_days = 30
}

# ── IAM ──────────────────────────────────────────────────
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals { type = "Service"; identifiers = ["lambda.amazonaws.com"] }
  }
}

data "aws_iam_policy_document" "lambda_policy" {
  statement {
    sid     = "DynamoDBAccess"
    actions = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem",
               "dynamodb:DeleteItem", "dynamodb:Query", "dynamodb:Scan"]
    resources = [aws_dynamodb_table.main.arn, "${aws_dynamodb_table.main.arn}/index/*"]
  }
  statement {
    sid     = "Logs"
    actions = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.lambda.arn}:*"]
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.project}-lambda-${var.env}"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy" "lambda" {
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_policy.json
}

# ── Lambda ───────────────────────────────────────────────
data "archive_file" "handler" {
  type        = "zip"
  source_dir  = "${path.root}/../src"
  output_path = "${path.root}/../dist/handler.zip"
}

resource "aws_lambda_function" "api" {
  function_name    = "${var.project}-${var.env}"
  filename         = data.archive_file.handler.output_path
  source_code_hash = data.archive_file.handler.output_base64sha256
  role             = aws_iam_role.lambda.arn
  handler          = var.lambda_handler
  runtime          = "nodejs20.x"
  architectures    = ["arm64"]
  timeout          = 29
  memory_size      = 256

  reserved_concurrent_executions = var.lambda_reserved_concurrency

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.main.name
      LOG_LEVEL  = "INFO"
    }
  }

  logging_config {
    log_format = "JSON"
    log_group  = aws_cloudwatch_log_group.lambda.name
  }

  depends_on = [aws_cloudwatch_log_group.lambda]
}

resource "aws_lambda_alias" "live" {
  name             = "live"
  function_name    = aws_lambda_function.api.function_name
  function_version = aws_lambda_function.api.version
}

# ── API Gateway HTTP API ──────────────────────────────────
resource "aws_apigatewayv2_api" "main" {
  name          = "${var.project}-${var.env}"
  protocol_type = "HTTP"

  cors_configuration {
    allow_headers = ["content-type", "authorization"]
    allow_methods = ["GET", "POST", "PUT", "DELETE", "OPTIONS"]
    allow_origins = var.cors_allow_origins
    max_age       = 300
  }
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_alias.live.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "proxy" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_stage" "prod" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = var.apigw_throttle_burst
    throttling_rate_limit  = var.apigw_throttle_rate
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.apigw.arn
  }
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  qualifier     = aws_lambda_alias.live.name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

# ── CloudWatch Alarms ─────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${var.project}-lambda-errors-${var.env}"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.api.function_name }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  alarm_actions       = var.alarm_sns_arns
}

resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  alarm_name          = "${var.project}-lambda-throttles-${var.env}"
  namespace           = "AWS/Lambda"
  metric_name         = "Throttles"
  dimensions          = { FunctionName = aws_lambda_function.api.function_name }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 10
  comparison_operator = "GreaterThanOrEqualToThreshold"
  alarm_actions       = var.alarm_sns_arns
}

resource "aws_cloudwatch_metric_alarm" "apigw_5xx" {
  alarm_name          = "${var.project}-apigw-5xx-${var.env}"
  namespace           = "AWS/ApiGateway"
  metric_name         = "5XXError"
  dimensions          = { ApiId = aws_apigatewayv2_api.main.id }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 10
  comparison_operator = "GreaterThanOrEqualToThreshold"
  alarm_actions       = var.alarm_sns_arns
}