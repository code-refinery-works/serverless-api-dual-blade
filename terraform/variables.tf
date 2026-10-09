variable "aws_region" {
  type    = string
  default = "ap-northeast-1"
}

variable "project" {
  type    = string
  default = "serverless-api"
}

variable "env" {
  type    = string
  default = "prod"
}

variable "lambda_handler" {
  type    = string
  default = "index.handler"
}

variable "lambda_reserved_concurrency" {
  type        = number
  default     = 100
  description = "Lambda reserved concurrent executions. Set -1 for unreserved."
}

variable "apigw_throttle_burst" {
  type    = number
  default = 500
}

variable "apigw_throttle_rate" {
  type    = number
  default = 1000
}

variable "cors_allow_origins" {
  type    = list(string)
  default = ["https://example.com"]
}

variable "alarm_sns_arns" {
  type        = list(string)
  default     = []
  description = "SNS topic ARNs for CloudWatch Alarms."
}