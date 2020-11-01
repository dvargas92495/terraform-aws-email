provider "aws" {
    region = "us-east-1"
}

module "email" {
    source = "../.."

    domain = "example.davidvargas.me"
}
