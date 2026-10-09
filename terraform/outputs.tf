output "api_endpoint" {
  description = "HTTP API invoke URL"
  value       = aws_apigatewayv2_api.main.api_endpoint
}

output "dynamodb_table_name" {
  description = "DynamoDB table name"
  value       = aws_dynamodb_table.main.name
}

output "dynamodb_table_arn" {
  description = "DynamoDB table ARN"
  value       = aws_dynamodb_table.main.arn
}

output "lambda_function_name" {
  description = "Lambda function name"
  value       = aws_lambda_function.api.function_name
}

output "lambda_function_arn" {
  description = "Lambda function ARN"
  value       = aws_lambda_function.api.arn
}

output "lambda_alias_arn" {
  description = "Lambda live alias ARN"
  value       = aws_lambda_alias.live.arn
}

output "lambda_log_group" {
  description = "Lambda CloudWatch Log Group name"
  value       = aws_cloudwatch_log_group.lambda.name
}