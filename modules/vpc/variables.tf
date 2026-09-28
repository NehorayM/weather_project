
variable "project" {
  type        = string
  description = "Name prefix for all resources"
}

variable "region" {
  type = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "domain_name" {
  type        = string
  description = "Route 53 hosted zone, e.g. nehorai-menashe.click"
}
