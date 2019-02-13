#!/bin/bash
set -eux

config_fqdn=$(hostname --fqdn)
config_ip=10.10.10.101
config_jenkins_master_fqdn='jenkins.example.com'
config_jenkins_master_ip=10.10.10.100

echo 'Defaults env_keep += "DEBIAN_FRONTEND"' >/etc/sudoers.d/env_keep_apt
chmod 440 /etc/sudoers.d/env_keep_apt
export DEBIAN_FRONTEND=noninteractive

#
# make sure the package index cache is up-to-date before installing anything.

apt-get update

#
# install dependencies.

apt-get install -y openjdk-8-jre-headless


#
# add the jenkins user.

groupadd --system jenkins
adduser \
    --system \
    --disabled-login \
    --no-create-home \
    --gecos '' \
    --ingroup jenkins \
    --home /var/jenkins \
    --shell /bin/bash \
    jenkins


#
# install the slave.

install -d -o jenkins -g jenkins -m 750 /var/jenkins
pushd /var/jenkins
install -d -o jenkins -g jenkins -m 750 {bin,lib,.ssh}
install -o jenkins -g jenkins -m 640 /dev/null .ssh/authorized_keys
cat /vagrant/tmp/$config_jenkins_master_fqdn-ssh-rsa.pub >>.ssh/authorized_keys
cat >bin/jenkins-slave <<EOF
#!/bin/sh
exec java -jar $PWD/lib/slave.jar
EOF
chmod +x bin/jenkins-slave
wget -q http://$config_jenkins_master_ip:8080/jnlpJars/slave.jar -O lib/slave.jar
popd


#
# install and configure git.

apt-get install -y git-core
su jenkins -c bash <<'EOF'
set -eux
git config --global user.email 'jenkins@example.com'
git config --global user.name 'Jenkins'
git config --global push.default simple
git config --global core.autocrlf false
EOF


#
# create artifacts that need to be shared with the other nodes.

mkdir -p /vagrant/tmp
pushd /vagrant/tmp
find \
    /etc/ssh \
    -name 'ssh_host_*_key.pub' \
    -exec sh -c "(echo -n '$config_ip '; cat {})" \; \
    >$config_fqdn.ssh_known_hosts
popd
