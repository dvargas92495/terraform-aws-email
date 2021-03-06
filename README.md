# aws-email

Creates an email mail from domain using AWS SES and Route53.

## Features

- Creates a new SES Domain identity
- Configures DKIM with the identity
- Sets up the Route53 TXT and CNAME records needed to avoid spam filters.

## Usage

```hcl
provider "aws" {
    region = "us-east-1"
}

data "aws_route53_zone" "domain" {
  name         = "davidvargas.me."
}

module "aws_email" {
    source    = "dvargas92495/email/aws"

    domain    = "example.davidvargas.me"
    zone_id   = data.aws_route53_zone.domain.zone_id
}
```

## Inputs
- `domain` - The domain the email address will be associated with.
- `zone_id` - The zone id to attach the domain to.
- `forward_to` - The email address to forward emails to.
- `tags` - tags to add on to created resources

## Output

There are no exposed outputs
