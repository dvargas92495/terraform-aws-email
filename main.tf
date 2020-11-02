locals {
  mail_from_domain = "admin.${var.domain}"
  leading_subdomain = split(".", var.domain)[0]
  rule_set_name = "${local.leading_subdomain}-rules"
  email_identity = "support@${var.domain}"
}

resource "aws_ses_domain_identity" "domain" {
  domain = var.domain
}

resource "aws_ses_domain_dkim" "domain" {
  domain = aws_ses_domain_identity.domain.domain
}

resource "aws_ses_domain_mail_from" "domain" {
  domain           = aws_ses_domain_identity.domain.domain
  mail_from_domain = local.mail_from_domain
}

resource "aws_route53_record" "ses_verification_record" {
  zone_id = var.zone_id
  name    = "_amazonses.${aws_ses_domain_identity.domain.domain}"
  type    = "TXT"
  ttl     = "1800"
  records = [aws_ses_domain_identity.domain.verification_token]
}

resource "aws_route53_record" "dkim_record" {
  count   = 3
  zone_id = var.zone_id
  name    = "${element(aws_ses_domain_dkim.domain.dkim_tokens, count.index)}._domainkey.${aws_ses_domain_identity.domain.domain}"
  type    = "CNAME"
  ttl     = "1800"
  records = ["${element(aws_ses_domain_dkim.domain.dkim_tokens, count.index)}.dkim.amazonses.com"]
}

resource "aws_route53_record" "mail_from_txt_record" {
  zone_id = var.zone_id
  name    = local.mail_from_domain
  type    = "TXT"
  ttl     = "300"
  records = ["v=spf1 include:amazonses.com ~all"]
}

resource "aws_route53_record" "mail_from_mx_record" {
  zone_id = var.zone_id
  name    = local.mail_from_domain
  type    = "MX"
  ttl     = "1800"
  records = ["10 inbound-smtp.us-east-1.amazonaws.com"]
}

resource "aws_ses_receipt_rule_set" "main" {
  rule_set_name = local.rule_set_name
}

resource "aws_ses_active_receipt_rule_set" "main" {
  rule_set_name = local.rule_set_name
  depends_on = [
    aws_ses_receipt_rule_set.main
  ]
}

resource "aws_ses_email_identity" "identity" {
  email = local.email_identity
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "bucket_policy" {
  statement {
    actions = [
      "s3:PutObject",
    ]

    resources = [
      "arn:aws:s3:::${local.mail_from_domain}/*",
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
  bucket = local.mail_from_domain
  policy = data.aws_iam_policy_document.bucket_policy.json
}

resource "aws_ses_receipt_rule" "store" {
  name          = "store"
  rule_set_name = local.rule_set_name
  recipients    = [local.email_identity]
  enabled       = true
  scan_enabled  = true

  s3_action {
    bucket_name = aws_s3_bucket.emails.id
    position    = 1
  }

  depends_on = [
    aws_ses_active_receipt_rule_set.main
  ]
}

data "archive_file" "lambda" {
  type        = "zip"
  output_path = "lambda.zip"
  source {
    content  = templatefile("${path.module}/lambda-template.js", { from_email = local.email_identity, email_bucket = local.mail_from_domain, domain = var.domain, recipient = var.forward_to })
    filename = "lambda.js"
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
    resources = [aws_s3_bucket.emails.arn]
	}
}

resource "aws_iam_policy" "lambda_ses_policy" {
  name = "${local.leading_subdomain}-lambda-email"
  policy = data.aws_iam_policy_document.lambda_ses_policy.json
}

resource "aws_iam_role" "lambda_role" {
  name = "${local.leading_subdomain}-lambda-email"
  assume_role_policy = data.aws_iam_policy_document.lambda_ses_policy.json
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "attach" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_ses_policy.arn
}

resource "aws_lambda_function" "lambda_function" {
  function_name    = "${local.leading_subdomain}_ses-forward"
  role             = aws_iam_role.lambda_role.arn
  handler          = "lambda.handler"
  runtime          = "nodejs12.x"
  filename         = "lambda.zip"
  tags             = var.tags
  timeout          = 30
}
