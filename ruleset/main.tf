variable rule_set_name {
    type = string
}

variable mail_from_domain {
    type = string
}

variable forward_to {
    type = string
}

variable leading_subdomain {
    type = string
}

variable tags {
    type = map
}

resource "aws_ses_receipt_rule_set" "main" {
  rule_set_name = var.rule_set_name
}

resource "aws_ses_active_receipt_rule_set" "main" {
  rule_set_name = var.rule_set_name
  depends_on = [
    aws_ses_receipt_rule_set.main
  ]
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "bucket_policy" {
  statement {
    actions = [
      "s3:PutObject",
    ]

    resources = [
      "arn:aws:s3:::${var.mail_from_domain}/*",
    ]

    principals {
      type = "Service"
      identifiers = [
        "ses.amazonaws.com"
      ]
    }

    condition {
      test = "StringEquals"
      variable = "aws:Referer"
      values = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_s3_bucket" "emails" {
  bucket = var.mail_from_domain
  policy = data.aws_iam_policy_document.bucket_policy.json
}

resource "aws_ses_receipt_rule" "store" {
  name          = "store"
  rule_set_name = var.rule_set_name
  recipients    = []
  enabled       = true
  scan_enabled  = true

  s3_action {
    bucket_name = aws_s3_bucket.emails.id
    position    = 1
  }

  lambda_action {
    function_arn = aws_lambda_function.lambda_function.arn
    position     = 2
  }

  depends_on = [
    aws_ses_active_receipt_rule_set.main
  ]
}

data "archive_file" "lambda" {
  type        = "zip"
  output_path = "lambda.zip"
  source {
    content  = templatefile("${path.module}/lambda-template.js", { email_bucket = var.mail_from_domain, recipient = var.forward_to })
    filename = "lambda.js"
  }
}

data "aws_iam_policy_document" "assume_lambda_policy" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "lambda_ses_policy" {
  statement {
    actions = [
      "ses:sendRawEmail",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:CreateLogGroup"
    ]
    resources = ["*"]
	}

  statement {
    actions = [
      "s3:GetObject",
      "s3:PutObject"
    ]
    resources = ["${aws_s3_bucket.emails.arn}/*"]
  }
}

resource "aws_iam_policy" "lambda_ses_policy" {
  name = "${var.leading_subdomain}-lambda-email"
  policy = data.aws_iam_policy_document.lambda_ses_policy.json
}

resource "aws_iam_role" "lambda_role" {
  name = "${var.leading_subdomain}-lambda-email"
  assume_role_policy = data.aws_iam_policy_document.assume_lambda_policy.json
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "attach" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_ses_policy.arn
}

resource "aws_lambda_function" "lambda_function" {
  function_name    = "${var.leading_subdomain}_ses-forward"
  role             = aws_iam_role.lambda_role.arn
  handler          = "lambda.handler"
  runtime          = "nodejs14.x"
  filename         = "lambda.zip"
  tags             = var.tags
  timeout          = 30
}

resource "aws_lambda_permission" "apigw_lambda" {
  statement_id   = "AllowExecutionFromSES"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.lambda_function.function_name
  principal      = "ses.amazonaws.com"
  source_account = data.aws_caller_identity.current.account_id
}
