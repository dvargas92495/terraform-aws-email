variable "domain" {
  type        = string
  description = "The domain the email address will be associated with."
}

variable "zone_id" {
  type        = string
  description = "The zone id to attach the domain to."
}
