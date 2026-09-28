

# repo for infestractier 

i created in gitlab a new repo for the infitractior

# install the aws lb contruller 

the controller is deployment that watches for ingress objects and calls the aws api to build albs listeners rules and target groups that match them 

that is the pice that moves a k8s object to aws infrastructure 

for that to happens it needds aws permissions i am giving them an iam role bound to the k8s service acount 
with pod identy so thears no access keys 


so after dowlonding the iam role 
from  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

i created inm the eks iam role fror the and bindinte to the lbc 

and seted a helm reles for to lbc


# moving to helm all the k8s services to helm and destroying the terrafrome infestractioer 

so terraform is owning the deployments and services
so i am removing them from terraform without destroying the the pods 
with terraform state rm it forget a resource while the object stil libe then i delete the code 
so state first the code second if i dealt the dcode first the next plan already wants to destroy the objects 



terraform state list | grep module.kubernetes

so thats all the resorces in the range of terrafrom of k8s 

module.kubernetes.kubernetes_deployment.app["dev"]
module.kubernetes.kubernetes_deployment.app["prod"]
module.kubernetes.kubernetes_deployment.app["staging"]
module.kubernetes.kubernetes_namespace.env["dev"]
module.kubernetes.kubernetes_namespace.env["prod"]
module.kubernetes.kubernetes_namespace.env["staging"]
module.kubernetes.kubernetes_namespace.jenkins
module.kubernetes.kubernetes_pod_disruption_budget_v1.app["dev"]
module.kubernetes.kubernetes_pod_disruption_budget_v1.app["prod"]
module.kubernetes.kubernetes_pod_disruption_budget_v1.app["staging"]
module.kubernetes.kubernetes_role.controller
module.kubernetes.kubernetes_role.deployer["dev"]
module.kubernetes.kubernetes_role.deployer["prod"]
module.kubernetes.kubernetes_role.deployer["staging"]
module.kubernetes.kubernetes_role_binding.controller
module.kubernetes.kubernetes_role_binding.deployer["dev"]
module.kubernetes.kubernetes_role_binding.deployer["prod"]
module.kubernetes.kubernetes_role_binding.deployer["staging"]
module.kubernetes.kubernetes_secret.controller_token
module.kubernetes.kubernetes_service.app["dev"]
module.kubernetes.kubernetes_service.app["prod"]
module.kubernetes.kubernetes_service.app["staging"]
module.kubernetes.kubernetes_service_account.agent
module.kubernetes.kubernetes_service_account.controller


terraform state rm 'module.kubernetes.kubernetes_deployment.app["prod"]'
terraform state rm 'module.kubernetes.kubernetes_deployment.app["staging"]'
terraform state rm 'module.kubernetes.kubernetes_deployment.app["dev"]'

terraform state rm 'module.kubernetes.kubernetes_service.app["prod"]'
terraform state rm 'module.kubernetes.kubernetes_service.app["staging"]'
terraform state rm 'module.kubernetes.kubernetes_service.app["dev"]'

terraform state rm 'module.kubernetes.kubernetes_pod_disruption_budget_v1.app["prod"]'
terraform state rm 'module.kubernetes.kubernetes_pod_disruption_budget_v1.app["staging"]'
terraform state rm 'module.kubernetes.kubernetes_pod_disruption_budget_v1.app["dev"]'

 kubectl get pods -A -l app=weather-app
NAMESPACE         NAME                           READY   STATUS    RESTARTS   AGE
weather-dev       weather-app-599ff9dcff-rkwdb   1/1     Running   0          5h27m
weather-prod      weather-app-74bfc7f855-4xqcc   1/1     Running   0          5h27m
weather-prod      weather-app-74bfc7f855-d7hjl   1/1     Running   0          5h27m
weather-prod      weather-app-74bfc7f855-p8t7w   1/1     Running   0          5h27m
weather-staging   weather-app-6d58d4486c-7wlvc   1/1     Running   0          5h27m


and as you can see all the pods are alive 
now i just dealting my .tf code that isint relevnt eny more 



then i created a new folder with all of the helm charts and pushed them the the new repo in gitlab 



# two albs

i deleted the infra namespace and the services and endpointslices from the k8s module

now i have two albs

the terraform alb keeps gitlab on 8000 and jenkins on 80 with the source ip rules

the k8s alb is created by the ingress objects and serves weather staging dev and argocd in one ingress group

different owner and different target type and different change rate

the second alb is about 55 cents a day

# dns

i deleted the app target groups from the terraform alb and set the https listener default action to a 404

then i added a data source for the k8s alb and moved weather staging and dev to it

gitlab and jenkins stay on the terraform alb

# argocd

installed from the official manifest into the argocd namespace

scaled dex and the notifications controller to 0 because i use local accounts and jenkins already sends slack

set server.insecure true in argocd-cmd-params-cm and restarted the server

without it the alb terminates tls and forwards plain http and argocd redirects back to https forever

opened 8080 on the node sg from the alb sg and created the argocd ingress in the same group

then i added the chart repo with the private address http://10.0.3.92:8000

the public name goes out through the nat and the nat ip is not in admin_cidrs so my own rule blocks it

# the applications

three files under apps for dev staging and prod and a root application under bootstrap that watches apps

dev and staging sync automatically with prune and self heal

prod is manual so i click sync after staging is checked

i also created one app in the gui and one with the cli and deleted them after

# the pipeline

jenkins does not touch the cluster any more

i deleted the deploy stage and the deployer role and rolebinding

now it builds and pushes to ecr then clones the chart repo and sets the image tag with yq and commits

develop goes to values-dev and release to values-staging and main to values-prod

argocd sees the commit and syncs

# read only user

added noam in argocd-cm and gave him role readonly plus a custom log-viewer role

logs is a separate rbac resource so readonly alone shows an empty logs tab

he can read the logs and he cannot sync



