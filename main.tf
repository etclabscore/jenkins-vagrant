provider "aws" {
  region     = "us-west-2"
}

resource "aws_instance" "jenkins-metal-cloud" {
  ami           = "ami-03fa1f014b48fa6bd"
  instance_type = "i3.metal"
  key_name      = "mbp"

  root_block_device {
    volume_size = 300
  }

  timeouts {
    create = "2h"
    delete = "2h"
  }

  provisioner "remote-exec" {
    connection {
      type = "ssh"
      user = "ubuntu"
      private_key = "${file("~/.ssh/id_rsa")}"
    }
    inline = [
      "wget -q https://www.virtualbox.org/download/oracle_vbox_2016.asc -O- | sudo apt-key add -",
      "wget -q https://www.virtualbox.org/download/oracle_vbox.asc -O- | sudo apt-key add -",
      "sudo apt-add-repository 'deb http://download.virtualbox.org/virtualbox/debian bionic contrib'",
      "sudo apt-get update",
      "sudo apt-get install unzip virtualbox -y",
      "wget https://releases.hashicorp.com/vagrant/2.2.3/vagrant_2.2.3_linux_amd64.zip",
      "unzip vagrant_2.2.3_linux_amd64.zip",
      "sudo mv vagrant /usr/local/bin/",
      "wget 'http://download.virtualbox.org/virtualbox/5.2.18/Oracle_VM_VirtualBox_Extension_Pack-5.2.18.vbox-extpack'",
      "echo y | sudo VBoxManage extpack install --replace Oracle_VM_VirtualBox_Extension_Pack-5.2.18.vbox-extpack",
      "git clone https://github.com/etclabscore/jenkins-vagrant.git && cd jenkins-vagrant",
      "git checkout feature/terraform",
      "vagrant plugin install --local",
      "vagrant up"
    ]
  }
}
