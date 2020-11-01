provider "aws" {
    region = "us-east-1"
}

data "aws_route53_zone" "domain" {
  name         = "davidvargas.me."
}

module "email" {
    source = "../.."

    domain  = "example.davidvargas.me"
    zone_id = data.aws_route53_zone.domain.zone_id
}
