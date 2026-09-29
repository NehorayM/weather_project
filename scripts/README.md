# scripts

Everything I run day to day. Every script has a comment at the top that says when to use it.
Run them from anywhere. They find the project folders by themselves.

## The day

```bash
scripts/apply.sh      # morning. everything up in about 30 minutes. no questions asked
scripts/status.sh     # any time. shows what is broken and which script fixes it
scripts/destroy.sh    # evening. saves GitLab and Jenkins then everything down
```

apply.sh ends with the status report. When every line is fine the day can start.
ArgoCD admin password for the day: `scripts/argocd-password.sh`

## When something is wrong

| What I see | What I run |
|---|---|
| GitLab or Jenkins says 403 Forbidden | `scripts/my-ip.sh` |
| kubectl says connection refused | `scripts/tunnel.sh` |
| a pipeline waits forever for an agent | `scripts/jenkins-sync.sh` |
| ArgoCD apps are missing or say authentication required | `scripts/argocd-bootstrap.sh` |
| a URL says 000 right after apply | nothing. DNS needs a minute |
| weather.nehorai-menashe.click says 404 | press Sync on weather-prod in ArgoCD. prod is manual on purpose |
| apply.sh stopped in the middle | run apply.sh again. it skips what already exists |
| destroy.sh says something is still there | fix it in the AWS console then `SKIP_BAKE=1 scripts/destroy.sh` |

## All the scripts

| Script | What it does |
|---|---|
| apply.sh | builds the whole environment from nothing |
| destroy.sh | bakes the AMIs then deletes everything except AMIs ECR and DNS zone |
| status.sh | read only health check of AWS the cluster ArgoCD Jenkins and every URL |
| tunnel.sh | the SSM tunnel to the private EKS API. reconnects by itself |
| my-ip.sh | adds my current IP to admin_cidrs |
| argocd-bootstrap.sh | installs ArgoCD and connects it to the chart repo |
| argocd-password.sh | prints the ArgoCD admin password |
| jenkins-sync.sh | points Jenkins at the new cluster of the day |
| bake-amis.sh | saves GitLab and Jenkins as AMIs. destroy.sh runs it |
| common.sh | settings shared by all of them. not run by itself |
| jenkins/eks-sync.groovy | runs inside Jenkins on start. jenkins-sync.sh installs it |

## Things that live outside git

- `terraform/terraform.tfvars` has the API key the Slack webhook and admin_cidrs
- `~/.config/weather-project/argocd-repo.env` has the GitLab deploy token ArgoCD uses.
  If it is lost make a new deploy token in GitLab with read_repository only.
  argocd-bootstrap.sh asks for it and saves it again
