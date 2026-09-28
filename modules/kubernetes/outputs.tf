output "jenkins_controller_token" {
  value     = kubernetes_secret.controller_token.data["token"]
  sensitive = true
}

output "namespaces" {
  value = { for k, ns in kubernetes_namespace.env : k => ns.metadata[0].name }
}
