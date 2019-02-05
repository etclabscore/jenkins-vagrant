#!/bin/bash
set -eu

config_fqdn=$(hostname)
config_jenkins_master_fqdn=$(hostname | sed -E 's,^[a-z]+\.,,')



#
# rename the hard disk.

diskutil rename disk0s2 macOS




#
# configure vim.

cat >~/.vimrc <<'EOF'
syntax on
set background=dark
set esckeys
set ruler
set laststatus=2
set nobackup
EOF


#
# configure the shell.

cat >~/.bash_profile <<'EOF'
# If not running interactively, don't do anything
[[ "$-" != *i* ]] && return

export EDITOR=vim
export PAGER=less

alias l='ls -lFG'
alias ll='l -a'
alias h='history 25'
alias j='jobs -l'
EOF

cat >~/.inputrc <<'EOF'
"\e[A": history-search-backward
"\e[B": history-search-forward
"\eOD": backward-word
"\eOC": forward-word
set show-all-if-ambiguous on
set completion-ignore-case on
EOF


#
# install the slave.

sudo bash <<SUDO_EOF
set -eux
mkdir -p /var/jenkins
mkdir -p /var/jenkins/w
pushd /var/jenkins
install -d -o jenkins -g jenkins -m 750 {bin,lib,.ssh,w}
install -o jenkins -g jenkins -m 640 /dev/null .ssh/authorized_keys
cat /vagrant/tmp/$config_jenkins_master_fqdn-ssh-rsa.pub >>.ssh/authorized_keys
cp .ssh/authorized_keys /Users/jenkins/.ssh/authorized_keys
security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain /vagrant/tmp/$config_jenkins_master_fqdn-crt.pem
cat >bin/jenkins-slave <<EOF
dseditgroup -o edit -t user -a jenkins com.apple.access_ssh
launchctl stop com.openssh.sshd
launchctl start com.openssh.sshd
#!/bin/sh
exec java -jar \$PWD/lib/slave.jar
EOF
chmod +x bin/jenkins-slave
curl https://$config_jenkins_master_fqdn/jnlpJars/slave.jar --cacert /vagrant/tmp/$config_jenkins_master_fqdn-crt.pem -o lib/slave.jar
popd
SUDO_EOF

#
# create artifacts that need to be shared with the other nodes.

sudo bash <<SUDO_EOF
set -eux
find /etc/ssh -name 'ssh_host_*_key.pub' -exec bash -c "(echo -n '$config_fqdn '; cat {})" \;
find /etc/ssh -name 'ssh_host_*_key.pub' -exec bash -c "(echo -n '$config_fqdn '; cat {})" \; > /vagrant/tmp/$config_fqdn.ssh_known_hosts
SUDO_EOF

#
# fix homebrew install

sudo bash <<SUDO_EOF
mkdir -p /usr/local/include
sudo chown -R jenkins $(brew --prefix)/*
SUDO_EOF

#
# install java

sudo -u jenkins bash <<SUDO_EOF
export HOMEBREW_CACHE=/Users/jenkins/Library/Homebrew/Cache
echo 'export HOMEBREW_CACHE=/Users/jenkins/Library/Homebrew/Cache' >> /Users/jenkins/.bash_profile
brew cask install java
SUDO_EOF


#
# results

sudo bash <<SUDO_EOF
uname -a
SUDO_EOF
