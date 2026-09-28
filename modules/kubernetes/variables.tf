variable "ecr_repository_url" {
  type = string
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
  type      = string
  sensitive = true
}
