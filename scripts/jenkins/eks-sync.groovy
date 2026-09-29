// eks-sync.groovy - runs inside Jenkins on every start (jenkins_home/init.groovy.d).
// Installed by scripts/jenkins-sync.sh, which also writes the three files it reads.
//
// Copies today's EKS API URL, CA certificate and service account token from
// jenkins_home/eks/ into the Kubernetes cloud config and the eks-sa-token credential.
// The cluster is rebuilt every day, so all three change every day.

import com.cloudbees.plugins.credentials.CredentialsScope
import com.cloudbees.plugins.credentials.SystemCredentialsProvider
import com.cloudbees.plugins.credentials.domains.Domain
import hudson.util.Secret
import jenkins.model.Jenkins
import org.csanchez.jenkins.plugins.kubernetes.KubernetesCloud
import org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl

def dir = new File(Jenkins.get().rootDir, 'eks')
def files = ['server_url', 'ca.crt', 'token'].collect { new File(dir, it) }
if (!files.every { it.exists() }) {
    println "eks-sync: no files in ${dir}, nothing to do"
    return
}
def (url, ca, token) = files.collect { it.text.trim() }

def store = SystemCredentialsProvider.getInstance().getStore()
def domain = Domain.global()
def fresh = new StringCredentialsImpl(CredentialsScope.GLOBAL, 'eks-sa-token',
        'EKS jenkins-controller token', Secret.fromString(token))
def old = store.getCredentials(domain).find { it.id == 'eks-sa-token' }
if (old) {
    store.updateCredentials(domain, old, fresh)
} else {
    store.addCredentials(domain, fresh)
}

def cloud = Jenkins.get().clouds.find { it instanceof KubernetesCloud }
if (cloud == null) {
    println 'eks-sync: no Kubernetes cloud configured'
    return
}
cloud.serverUrl = url
cloud.serverCertificate = ca
Jenkins.get().save()
println "eks-sync: kubernetes cloud now points at ${url}"
