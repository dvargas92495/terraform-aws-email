locals {
  mail_from_domain = "admin.${var.domain}"
  leading_subdomain = replace(replace(var.domain, "/\\..*$/", ""), ".", "-")
  rule_set_name = "${local.leading_subdomain}-rules"
  email_identity = "${var.email_identity}@${var.domain}"
  domain_parts = split(var.domain, ".")
  tags = length(var.tags) > 0 ? var.tags : {
    Application = join(slice(var.domain_parts, length(var.domain_parts) - 2, length(var.domain_parts)), "-")
  }
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
  name    = var.domain
  type    = "MX"
  ttl     = "1800"
  records = ["10 inbound-smtp.us-east-1.amazonaws.com"]
}

resource "aws_ses_email_identity" "identity" {
  email = local.email_identity
}

module "ruleset" {
  source = "./ruleset"
  count = length(var.forward_to) ? 1 : 0

  rule_set_name = local.rule_set_name
  mail_from_domain = local.mail_from_domain
  forward_to = var.forward_to
  leading_subdomain = local.leading_subdomain
  tags = local.tags
}
