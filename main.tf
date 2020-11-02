locals {
  mail_from_domain = "admin.${var.domain}"
  leading_subdomain = split(".", var.domain)[0]
  rule_set_name = "${local.leading_subdomain}-rules"
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

resource "aws_ses_active_receipt_rule_set" "main" {
  rule_set_name = local.rule_set_name
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

    principal {
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
  recipients    = ["support@${var.domain}"]
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
