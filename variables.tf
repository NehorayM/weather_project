# Root variables.
#
# Every `var.X` you reference in the root files must be declared HERE. The
# variables.tf inside modules/infrastructure is a separate namespace and does
# not satisfy the root. That is what your "undeclared variable" errors are.

variable "project" {
  type        = string
  description = "Name prefix for all resources"
}

variable "region" {
  type        = string
  description = "AWS region. Must match the region your golden AMIs live in."
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "domain_name" {
  type        = string
  description = "Route 53 hosted zone, e.g. nehorai-menashe.click"
}

variable "gitlab_ami_id" {
  type        = string
  description = "Golden AMI baked from the working GitLab instance"
}

variable "jenkins_ami_id" {
  type        = string
  description = "Golden AMI baked from the working Jenkins controller"
}

variable "cluster_version" {
  type    = string
  default = "1.36"
}


variable "admin_cidrs" {
  type = list(string)
}
variable "environments" {
  type = map(object({
    subdomain = string
  }))

  default = {
    prod    = { subdomain = "weather" }
    staging = { subdomain = "staging" }
    dev     = { subdomain = "dev" }
  }
}
variable "weather_api_key" {
  type      = string
  sensitive = true
}
variable "slack_webhook_url" {
  description = "Slack Webhook URL for Alertmanager"
  type        = string
  sensitive   = true
}
