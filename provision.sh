#!/bin/bash
set -eux

domain='jenkins.example.com'

echo 'Defaults env_keep += "DEBIAN_FRONTEND"' >/etc/sudoers.d/env_keep_apt
chmod 440 /etc/sudoers.d/env_keep_apt
export DEBIAN_FRONTEND=noninteractive


#
# make sure the package index cache is up-to-date before installing anything.

apt-get update


#
# install a EGD (Entropy Gathering Daemon).
# NB the host should have an EGD and expose/virtualize it to the guest.
#    on libvirt there's virtio-rng which will read from the host /dev/random device
#    so your host should have a TRNG (True RaNdom Generator) with rng-tools
#    reading from it and feeding it into /dev/random or have the haveged
#    daemon running.
# see https://wiki.qemu.org/Features/VirtIORNG
# see https://wiki.archlinux.org/index.php/Rng-tools
# see https://www.kernel.org/doc/Documentation/hw_random.txt
# see https://hackaday.com/2017/11/02/what-is-entropy-and-how-do-i-get-more-of-it/
# see cat /sys/devices/virtual/misc/hw_random/rng_current
# see cat /proc/sys/kernel/random/entropy_avail
# see rngtest -c 1000 </dev/hwrng
# see rngtest -c 1000 </dev/random
# see rngtest -c 1000 </dev/urandom
apt-get install -y rng-tools


#
# enable systemd-journald persistent logs.

sed -i -E 's,^#?(Storage=).*,\1persistent,' /etc/systemd/journald.conf
systemctl restart systemd-journald


#
# configure the shell.

cat >~/.bash_history <<'EOF'
systemctl status jenkins
systemctl restart jenkins
less /var/log/jenkins/jenkins.log
tail -f /var/log/jenkins/jenkins.log
tail -f /var/log/jenkins/access.log | grep -v ajax
cat /var/lib/jenkins/secrets/initialAdminPassword
cd /var/lib/jenkins
netstat -antp
sudo -sHu jenkins
EOF

cat >~/.bashrc <<'EOF'
alias jcli="java -jar /var/cache/jenkins/war/WEB-INF/jenkins-cli.jar -s http://localhost:8080 -http -auth @$HOME/.jenkins-cli"
alias jgroovy='jcli groovy'
EOF


#
# install dependencies.

apt-get install -y openjdk-8-jre-headless
apt-get install -y gnupg
apt-get install -y xmlstarlet


#
# fix "java.lang.NoClassDefFoundError: Could not initialize class org.jfree.chart.JFreeChart"
# error while rendering the xUnit Test Result Trend chart on the job page.

sed -i -E 's,^(\s*assistive_technologies\s*=.*),#\1,' /etc/java-8-openjdk/accessibility.properties 


#
# install Jenkins.
# TODO: lock down to specific version of jenkins

wget -qO- https://pkg.jenkins.io/debian-stable/jenkins.io.key | apt-key add -
echo 'deb http://pkg.jenkins.io/debian-stable binary/' >/etc/apt/sources.list.d/jenkins.list
apt-get update
apt-get install -y --no-install-recommends jenkins
pushd /var/lib/jenkins
# wait for initialization to finish.
bash -c 'while [ "$(xmlstarlet sel -t -v /hudson/installStateName config.xml 2>/dev/null)" != "NEW" ]; do sleep 1; done'
systemctl stop jenkins
chmod 751 /var/cache/jenkins
mv config.xml{,.orig}
# remove the xml 1.1 declaration because xmlstarlet does not support it... and xml 1.1 is not really needed.
tail -n +2 config.xml.orig >config.xml
# disable security.
# see https://wiki.jenkins-ci.org/display/JENKINS/Disable+security
xmlstarlet edit --inplace -u '/hudson/useSecurity' -v 'false' config.xml
xmlstarlet edit --inplace -d '/hudson/authorizationStrategy' config.xml
xmlstarlet edit --inplace -d '/hudson/securityRealm' config.xml
# disable the install wizard.
xmlstarlet edit --inplace -u '/hudson/installStateName' -v 'RUNNING' config.xml
# modify the slave workspace directory name to be just "w" as a way to minimize
# path-too-long errors on windows slaves.
# NB unfortunately this setting applies to all slaves.
# NB in a pipeline job you can also use the customWorkspace option.
# see windows/provision-jenkins-slaves.ps1.
# see https://issues.jenkins-ci.org/browse/JENKINS-12667
# see https://wiki.jenkins.io/display/JENKINS/Features+controlled+by+system+properties
# see https://github.com/jenkinsci/jenkins/blob/jenkins-2.138.2/core/src/main/java/hudson/model/Slave.java#L722
sed -i -E 's,^(JAVA_ARGS="-.+),\1\nJAVA_ARGS="$JAVA_ARGS -Dhudson.model.Slave.workspaceRoot=w",' /etc/default/jenkins
# bind to localhost.
sed -i -E 's,^(JENKINS_ARGS="-.+),\1\nJENKINS_ARGS="$JENKINS_ARGS --httpListenAddress=0.0.0.0",' /etc/default/jenkins
# configure access log.
# NB this is useful for testing whether static files are really being handled by nginx.
sed -i -E 's,^(JENKINS_ARGS="-.+),\1\nJENKINS_ARGS="$JENKINS_ARGS --accessLoggerClassName=winstone.accesslog.SimpleAccessLogger --simpleAccessLogger.format=combined --simpleAccessLogger.file=/var/log/jenkins/access.log",' /etc/default/jenkins
sed -i -E 's,^(/var/log/jenkins/)jenkins.log,\1*.log,' /etc/logrotate.d/jenkins
# show the configuration changes.
diff -u config.xml{.orig,} || true
popd
systemctl start jenkins
bash -c 'while ! wget -q --spider http://localhost:8080/cli; do sleep 1; done;'


#
# configure Jenkins.

# import the cli and redefine jcli for not using any authentication while we configure jenkins.
source /vagrant/jenkins-cli.sh
function jcli {
    $JCLI -noKeyAuth "$@"
}

# customize.
# see http://javadoc.jenkins-ci.org/jenkins/model/Jenkins.html
jgroovy = <<'EOF'
import hudson.model.Node.Mode
import jenkins.model.Jenkins

// disable usage statistics.
Jenkins.instance.noUsageStatistics = true

// do not run jobs on the master.
Jenkins.instance.numExecutors = 0
Jenkins.instance.mode = Mode.EXCLUSIVE

Jenkins.instance.save()
EOF

# install and configure git.
apt-get install -y git-core
su jenkins -c bash <<'EOF'
set -eux
git config --global user.email 'jenkins@example.com'
git config --global user.name 'Jenkins'
git config --global push.default simple
git config --global core.autocrlf false
EOF

# install plugins.
# NB installing plugins is quite flaky, mainly because Jenkins (as-of 2.19.2)
#    does not retry their downloads. this will workaround it by (re)installing
#    until it works.
# see http://javadoc.jenkins-ci.org/jenkins/model/Jenkins.html
# see http://javadoc.jenkins-ci.org/hudson/PluginManager.html
# see http://javadoc.jenkins.io/hudson/model/UpdateCenter.html
# see http://javadoc.jenkins.io/hudson/model/UpdateSite.Plugin.html
jgroovy = <<'EOF'
import jenkins.model.Jenkins
Jenkins.instance.updateCenter.updateAllSites()
EOF
function install-plugins {
jgroovy = <<'EOF'
import jenkins.model.Jenkins

updateCenter = Jenkins.instance.updateCenter
pluginManager = Jenkins.instance.pluginManager

installed = [] as Set

def install(id) {
  plugin = updateCenter.getPlugin(id)

  plugin.dependencies.each {
    install(it.key)
  }

  if (!pluginManager.getPlugin(id) && !installed.contains(id)) {
    println("installing plugin ${id}...")
    pluginManager.install([id], false).each { it.get() }
    installed.add(id)
  }
}

[
    'git',
    'powershell',
    'blueocean',
].each {
  install(it)
}
EOF
}
while [[ -n "$(install-plugins)" ]]; do
    systemctl restart jenkins
    bash -c 'while ! wget -q --spider http://localhost:8080/cli; do sleep 1; done;'
done

#
# configure security.

# generate the SSH key-pair that jenkins master uses to communicates with the slaves.
su jenkins -c 'ssh-keygen -q -t rsa -N "" -f ~/.ssh/id_rsa'

# disable all JNLP agent protocols.
# see http://javadoc.jenkins-ci.org/jenkins/model/Jenkins.html
jgroovy = <<'EOF'
import jenkins.model.Jenkins

Jenkins.instance.agentProtocols = Jenkins.instance.agentProtocols.grep { !it.matches('^JNLP.+-connect$') }
Jenkins.instance.save()
EOF

# enable simple security.
# also create the vagrant user account. jcli will use this account from now on.
# see http://javadoc.jenkins-ci.org/hudson/security/HudsonPrivateSecurityRealm.html
# see http://javadoc.jenkins-ci.org/hudson/model/User.html
jgroovy = <<'EOF'
import jenkins.model.Jenkins
import hudson.security.HudsonPrivateSecurityRealm
import hudson.security.FullControlOnceLoggedInAuthorizationStrategy
import hudson.tasks.Mailer

Jenkins.instance.securityRealm = new HudsonPrivateSecurityRealm(false)

u = Jenkins.instance.securityRealm.createAccount('vagrant', 'vagrant')
u.fullName = 'Vagrant'
u.save()

Jenkins.instance.authorizationStrategy = new FullControlOnceLoggedInAuthorizationStrategy(
  allowAnonymousRead: true)

Jenkins.instance.save()
EOF

# create the vagrant user api token.
# see http://javadoc.jenkins-ci.org/hudson/model/User.html
# see http://javadoc.jenkins-ci.org/jenkins/security/ApiTokenProperty.html
# see https://jenkins.io/doc/book/managing/cli/
function jcli {
    $JCLI -http -auth vagrant:vagrant "$@"
}
jgroovy = >~/.jenkins-cli <<'EOF'
import hudson.model.User
import jenkins.security.ApiTokenProperty

u = User.current()
p = u.getProperty(ApiTokenProperty)
t = p.tokenStore.generateNewToken('vagrant')
u.save()
println sprintf("%s:%s", u.id, t.plainValue)
EOF
chmod 400 ~/.jenkins-cli

# redefine jcli to use the vagrant api token.
source /vagrant/jenkins-cli.sh

# show which user is actually being used in jcli. this should show "vagrant".
# see http://javadoc.jenkins-ci.org/hudson/model/User.html
jgroovy = <<'EOF'
import hudson.model.User

u = User.current()
println sprintf("User id: %s", u.id)
println sprintf("User Full Name: %s", u.fullName)
u.allProperties.each { println sprintf("User property: %s", it) }; null
EOF


#
# create artifacts that need to be shared with the other nodes.

mkdir -p /vagrant/tmp
pushd /vagrant/tmp
cp /var/lib/jenkins/.ssh/id_rsa.pub $domain-ssh-rsa.pub
popd


#
# add the ubuntu slave node.
# see http://javadoc.jenkins-ci.org/jenkins/model/Jenkins.html
# see http://javadoc.jenkins-ci.org/jenkins/model/Nodes.html
# see http://javadoc.jenkins-ci.org/hudson/slaves/DumbSlave.html
# see http://javadoc.jenkins-ci.org/hudson/model/Computer.html

jgroovy = <<'EOF'
import jenkins.model.Jenkins
import hudson.slaves.DumbSlave
import hudson.slaves.CommandLauncher

node = new DumbSlave(
    "ubuntu",
    "/var/jenkins",
    new CommandLauncher("ssh 10.10.10.101 /var/jenkins/bin/jenkins-slave"))
node.numExecutors = 3
node.labelString = "ubuntu 18.04 linux amd64"
Jenkins.instance.nodesObject.addNode(node)
Jenkins.instance.nodesObject.save()
EOF


#
# add the windows slave node.

jgroovy = <<'EOF'
import jenkins.model.Jenkins
import hudson.slaves.DumbSlave
import hudson.slaves.CommandLauncher

node = new DumbSlave(
    "windows",
    "c:/j",
    new CommandLauncher("ssh 10.10.10.102 java -jar c:/j/lib/slave.jar"))
node.numExecutors = 3
node.labelString = "windows server 2019"
Jenkins.instance.nodesObject.addNode(node)
Jenkins.instance.nodesObject.save()
EOF


#
# add the macos slave node.

jgroovy = <<'EOF'
import jenkins.model.Jenkins
import hudson.slaves.DumbSlave
import hudson.slaves.CommandLauncher

node = new DumbSlave(
    "macos",
    "/var/jenkins",
    new CommandLauncher("ssh 10.10.10.103 /var/jenkins/bin/jenkins-slave"))
node.numExecutors = 3
node.labelString = "macos 10.14 Mojave"
Jenkins.instance.nodesObject.addNode(node)
Jenkins.instance.nodesObject.save()
EOF


# remove insecure vagrant user
#jgroovy = <<'EOF'
#import hudson.model.User
#u = User.current()
#u.delete()
#EOF
