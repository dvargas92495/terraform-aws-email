variable "domain" {
  type        = string
  description = "The domain the email address will be associated with."
}

variable "zone_id" {
  type        = string
  description = "The zone id to attach the domain to."
}

variable "tags" {
    type        = map
    description = "A map of tags to add to all resources"
    default     = {}
}
