terraform {
    backend "local" {
        path = "terraform.tfstate"
    }
}

provider "aws" {
    region  = var.aws_region
    profile = var.aws_profile
}

variable "aws_profile" {
    type = string
    default = null
}

variable "aws_region" {
    type = string
    default = "eu-west-1"
}

resource "aws_iam_policy" "api_firehose_policy" {
  name        = "API-Firehose"
  
  policy = jsonencode({
   Version = "2012-10-17"
    Statement = [
      {
        "Sid": "VisualEditor0",
        Action = [
          "firehose:PutRecord",
        ]
        Effect = "Allow"
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role" "api_gateway_firehose_role" {
  name = "APIGateway-Firehose"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "apigateway.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "api_firehose_policy_attach" {
  role       = aws_iam_role.api_gateway_firehose_role.name
  policy_arn = aws_iam_policy.api_firehose_policy.arn
}

resource "aws_iam_role_policy_attachment" "api_cw_logs_policy_attach" {
  role       = aws_iam_role.api_gateway_firehose_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

resource "aws_s3_bucket" "data_store_s3_bucket" { 
    bucket = "data-store-s3-bucket-vn"
}

data "archive_file" "transform_data_lambda_archive" {
  type        = "zip"
  source_file = "transform_data.py"
  output_path = "transform_data.zip"
}

resource "aws_lambda_function" "transform_data_lambda" {
    function_name = "transform-data"
    role = aws_iam_role.transform_data_lambda_role.arn
    filename = data.archive_file.transform_data_lambda_archive.output_path
    handler = "transform_data.lambda_handler"
    publish = true

    timeout = 10
    runtime = "python3.8"
}

resource "aws_iam_role" "transform_data_lambda_role" {
  name = "transform_data_lambdaexecution_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "lambda.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_policy" "transform_data_lambda_policy" {
  name        = "transform_data_lambda_policy"
  description = "Basic policy for Lambda function"
  
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_policy_attachment" {
  role       = aws_iam_role.transform_data_lambda_role.name
  policy_arn = aws_iam_policy.transform_data_lambda_policy.arn
}

########################## Firehose ###########################
resource "aws_iam_role" "firehose_role" {
  name = "firehose_delivery_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "firehose.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_policy" "firehose_policy" {
  name = "firehose_delivery_policy"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = "s3:PutObject",
        Resource = "${aws_s3_bucket.data_store_s3_bucket.arn}/*"
      },
      {
        Effect = "Allow",
        Action = [
          "lambda:InvokeFunction",
          "lambda:GetFunctionConfiguration"
        ],
        Resource = "${aws_lambda_function.transform_data_lambda.arn}:$LATEST"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "firehose_policy_attachment" {
  role       = aws_iam_role.firehose_role.name
  policy_arn = aws_iam_policy.firehose_policy.arn
}


resource "aws_kinesis_firehose_delivery_stream" "data_kinesis_firehose_delivery_stream" {
    name = "data_kinesis_firehose_delivery_stream"
    destination = "extended_s3"

  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose_role.arn
    bucket_arn = aws_s3_bucket.data_store_s3_bucket.arn
    buffering_size        = 10
    buffering_interval    = 400

     processing_configuration {
      enabled = "true"

      processors {
        type = "Lambda"

        parameters {
          parameter_name  = "LambdaArn"
          parameter_value = "${aws_lambda_function.transform_data_lambda.arn}:$LATEST"
        }
      }
    }
  }
}

############## API Gateway ###################
resource "aws_api_gateway_rest_api" "clickstream-ingest-poc-api"{
    name = "clickstream-ingest-poc"
    endpoint_configuration {
      types = [ "REGIONAL" ]
    }
}

resource "aws_api_gateway_resource" "clickstream-ingest-poc-api_resource" {
  rest_api_id = aws_api_gateway_rest_api.clickstream-ingest-poc-api.id
  parent_id   = aws_api_gateway_rest_api.clickstream-ingest-poc-api.root_resource_id
  path_part   = "poc"
}

resource "aws_api_gateway_method" "api_method" {
  rest_api_id   = aws_api_gateway_rest_api.clickstream-ingest-poc-api.id
  resource_id   = aws_api_gateway_resource.clickstream-ingest-poc-api_resource.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_method_response" "api_method_response" {
  rest_api_id   = aws_api_gateway_rest_api.clickstream-ingest-poc-api.id
  resource_id   = aws_api_gateway_resource.clickstream-ingest-poc-api_resource.id
  http_method = aws_api_gateway_method.api_method.http_method
  status_code = "200"
}

resource "aws_api_gateway_integration_response" "integration_response" {
  rest_api_id   = aws_api_gateway_rest_api.clickstream-ingest-poc-api.id
  resource_id   = aws_api_gateway_resource.clickstream-ingest-poc-api_resource.id
  http_method = aws_api_gateway_method.api_method.http_method
  status_code = aws_api_gateway_method_response.api_method_response.status_code

  response_templates = {
    "application/json" = ""
  }
}

resource "aws_api_gateway_integration" "api_integration" {
  rest_api_id = aws_api_gateway_rest_api.clickstream-ingest-poc-api.id
  resource_id = aws_api_gateway_resource.clickstream-ingest-poc-api_resource.id
  http_method = aws_api_gateway_method.api_method.http_method

  type                    = "AWS"
  integration_http_method = "POST"
  uri                     = "arn:aws:apigateway:${var.aws_region}:firehose:action/PutRecord"
  credentials             = aws_iam_role.api_gateway_firehose_role.arn

  request_templates = {
    "application/json" = jsonencode({
      DeliveryStreamName = "${aws_kinesis_firehose_delivery_stream.data_kinesis_firehose_delivery_stream.name}"
      Record = {
        Data = "$util.base64Encode($util.escapeJavaScript($input.json('$')).replace('\\', ''))"
      }
    })
  }

}

resource "aws_api_gateway_deployment" "api_deployment" {
  depends_on = [
    aws_api_gateway_integration.api_integration
  ]

  rest_api_id = aws_api_gateway_rest_api.clickstream-ingest-poc-api.id
  stage_name  = "prod"
}

################Athena###############
resource "aws_athena_database" "click_stream_db" {
  name = "click_stream_db"
  bucket = aws_s3_bucket.data_store_s3_bucket.bucket
}

resource "aws_athena_named_query" "create_table_query" {
  name        = "click_stream_table"
  database    = aws_athena_database.click_stream_db.name
  description = "Create click_stream_table"
  query       = <<-EOT
CREATE EXTERNAL TABLE IF NOT EXISTS my_ingested_data (
  element_clicked STRING,
  time_spent INT,
  source_menu STRING,
  created_at STRING
)
PARTITIONED BY (
  datehour STRING
)
ROW FORMAT SERDE 'org.openx.data.jsonserde.JsonSerDe'
WITH SERDEPROPERTIES ( 'paths'='element_clicked, time_spent, source_menu, created_at' )
LOCATION 's3://${aws_s3_bucket.data_store_s3_bucket.bucket}/'
TBLPROPERTIES (
  'projection.enabled' = 'true',
  'projection.datehour.type' = 'date',
  'projection.datehour.format' = 'yyyy/MM/dd/HH',
  'projection.datehour.range' = '2021/01/01/00,NOW',
  'projection.datehour.interval' = '1',
  'projection.datehour.interval.unit' = 'HOURS',
  'storage.location.template' = s3://${aws_s3_bucket.data_store_s3_bucket.bucket}/$${datehour}/
)
EOT
  workgroup = "primary"
}

resource "null_resource" "run_athena_query" {
  provisioner "local-exec" {
    command = <<EOT
      aws athena start-query-execution --query-string "${aws_athena_named_query.create_table_query.query}" --query-execution-context Database=${aws_athena_database.click_stream_db.name} --work-group "primary" --region ${var.aws_region} --profile=${var.aws_profile} --result-configuration OutputLocation=s3://${aws_s3_bucket.data_store_s3_bucket.bucket}/results/
    EOT
  }
}

output "create_table_query_id" {
  value = aws_athena_named_query.create_table_query.id
}