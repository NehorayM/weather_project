# ---------- namespaces ----------
# name space that is seprate for each env weather-dev, weather-staging, weather-prod
resource "kubernetes_namespace" "env" {
  for_each = var.environments

  metadata {
    name = "weather-${each.key}"

    labels = {
      environment                          = each.key
      "pod-security.kubernetes.io/enforce" = "restricted"
    }
  }
}
# name space for jenkins agent 
resource "kubernetes_namespace" "jenkins" {
  metadata {
    name = "jenkins"

    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
    }
  }
}




# ---------- identities and rabc ----------

# service account for the agent for push the code to the ecr repo and for the agent to be able to create pods in the eks cluster
resource "kubernetes_service_account" "agent" {
  metadata {
    name      = "jenkins-agent"
    namespace = kubernetes_namespace.jenkins.metadata[0].name
  }
}

# for the controller to be avle to create agent and talk with the api server and the agent 
resource "kubernetes_service_account" "controller" {
  metadata {
    name      = "jenkins-controller"
    namespace = kubernetes_namespace.jenkins.metadata[0].name
  }
}

# for tocken for the api server
resource "kubernetes_secret" "controller_token" {
  metadata {
    name      = "jenkins-controller-token"
    namespace = kubernetes_namespace.jenkins.metadata[0].name

    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account.controller.metadata[0].name
    }
  }

  type                           = "kubernetes.io/service-account-token"
  wait_for_service_account_token = true
}

# role for the controller to be able to create agent pods and talk with the api server
resource "kubernetes_role" "controller" {
  metadata {
    name      = "jenkins-controller"
    namespace = kubernetes_namespace.jenkins.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "pods/exec", "pods/log", "events"]
    verbs      = ["get", "list", "watch", "create", "delete"]
  }
}
# role binding for the controller to be able to create agent pods and talk with the api server
resource "kubernetes_role_binding" "controller" {
  metadata {
    name      = "jenkins-controller"
    namespace = kubernetes_namespace.jenkins.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.controller.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.controller.metadata[0].name
    namespace = kubernetes_namespace.jenkins.metadata[0].name
  }
}


resource "kubernetes_secret" "app" {
  for_each = var.environments

  metadata {
    name      = "weather-app-secrets"
    namespace = kubernetes_namespace.env[each.key].metadata[0].name
  }

  # each key becomes an environment variable in the pod through envFrom
  data = {
    API_KEY = var.weather_api_key
  }

  type = "Opaque"
}



# ---------- Monitoring Stack ----------

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }
}

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  allow_volume_expansion = true
  volume_binding_mode    = "WaitForFirstConsumer"

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }
}

resource "kubernetes_secret" "alertmanager_slack" {
  metadata {
    name      = "alertmanager-slack"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    "slack-url" = var.slack_webhook_url
  }

  type = "Opaque"
}
