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

module "aws_email" {
    source    = "dvargas92495/email/aws"

    domain    = "example.davidvargas.me"
}
```

## Inputs
- `domain` - The domain the email address will be associated with.
- `zone_id` - The zone id to attach the domain to.

## Output

There are no exposed outputs
