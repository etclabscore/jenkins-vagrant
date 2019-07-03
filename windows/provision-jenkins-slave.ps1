param(
    [Parameter(Mandatory=$true)]
    [string]$config_jenkins_master_fqdn = 'jenkins.example.com',

    [Parameter(Mandatory=$true)]
    [string]$config_fqdn = 'windows.jenkins.example.com',

    [Parameter(Mandatory=$true)]
    [string]$config_jenkins_master_ip = '10.10.10.100',

    [Parameter(Mandatory=$true)]
    [string]$config_ip = '10.10.10.102'
)

write-output ""
write-output "config_jenkins_master_fqdn: $config_jenkins_master_fqdn"
write-output "config_fqdn: $config_fqdn"
write-output "config_ip: $config_ip"
write-output "config_jenkins_master_ip: $config_jenkins_master_ip"

# install git and related applications.
choco install -y git --params '/GitOnlyOnPath /NoAutoCrlf /SChannel'
choco install -y gitextensions
choco install -y meld

# update $env:PATH with the recently installed Chocolatey packages.
Import-Module "$env:ChocolateyInstall\helpers\chocolateyInstaller.psm1"
Update-SessionEnvironment

# install troubeshooting tools.
choco install -y procexp
choco install -y procmon

# add start menu entries.
Install-ChocolateyShortcut `
    -ShortcutFilePath 'C:\Users\All Users\Microsoft\Windows\Start Menu\Programs\Process Explorer.lnk' `
    -TargetPath 'C:\ProgramData\chocolatey\lib\procexp\tools\procexp64.exe'
Install-ChocolateyShortcut `
    -ShortcutFilePath 'C:\Users\All Users\Microsoft\Windows\Start Menu\Programs\Process Monitor.lnk' `
    -TargetPath 'C:\ProgramData\chocolatey\lib\procmon\tools\procmon.exe'


# install the JRE.
choco install -y openjdk
Update-SessionEnvironment

# restart the SSH service so it can re-read the environment (e.g. the system environment
# variables like PATH) after we have installed all this slave node dependencies.
Restart-Service sshd

# create the jenkins user account and home directory.
[Reflection.Assembly]::LoadWithPartialName('System.Web') | Out-Null
$jenkinsAccountName = 'jenkins'
$jenkinsAccountPassword = [Web.Security.Membership]::GeneratePassword(32, 8)
$jenkinsAccountPasswordSecureString = ConvertTo-SecureString $jenkinsAccountPassword -AsPlainText -Force
$jenkinsAccountCredential = New-Object `
    Management.Automation.PSCredential `
    -ArgumentList `
        $jenkinsAccountName,
        $jenkinsAccountPasswordSecureString
New-LocalUser `
    -Name $jenkinsAccountName `
    -FullName 'Jenkins Slave' `
    -Password $jenkinsAccountPasswordSecureString `
    -PasswordNeverExpires
# login to force the system to create the home directory.
# NB the home directory will have the correct permissions, only the
#    SYSTEM, Administrators and the jenkins account are granted full
#    permissions to it.
Start-Process -WindowStyle Hidden -Credential $jenkinsAccountCredential -WorkingDirectory 'C:\' -FilePath cmd -ArgumentList '/c'

# configure the account to allow ssh connections from the jenkins master.
mkdir C:\Users\$jenkinsAccountName\.ssh | Out-Null
copy C:\vagrant\tmp\$config_jenkins_master_fqdn-ssh-rsa.pub C:\Users\$jenkinsAccountName\.ssh\authorized_keys

# configure the jenkins home.
choco install -y pstools
Copy-Item C:\vagrant\windows\configure-jenkins-home.ps1 C:\tmp
psexec `
    -accepteula `
    -nobanner `
    -u $jenkinsAccountName `
    -p $jenkinsAccountPassword `
    -h `
    PowerShell -File C:\tmp\configure-jenkins-home.ps1
Remove-Item C:\tmp\configure-jenkins-home.ps1

# create the storage directory hierarchy.
# grant the SYSTEM, Administrators and $jenkinsAccountName accounts
# Full Permissions to the c:\j directory and children.
$jenkinsDirectory = mkdir c:\j
$acl = New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
@(
    'SYSTEM'
    'Administrators'
    $jenkinsAccountName
) | ForEach-Object {
    $acl.AddAccessRule((
        New-Object `
            Security.AccessControl.FileSystemAccessRule(
                $_,
                'FullControl',
                'ContainerInherit,ObjectInherit',
                'None',
                'Allow')))
}
$jenkinsDirectory.SetAccessControl($acl)

# download the slave jar and install it.
$config_jenkins_url = $config_jenkins_master_ip + ':8080'
$config_jenkins_slave_url = "http://$config_jenkins_url/jnlpJars/slave.jar"
write-output "config_jenkins_url: $config_jenkins_url"
write-output "config_jenkins_slave_url: $config_jenkins_slave_url"

mkdir $jenkinsDirectory\lib | Out-Null
Invoke-WebRequest $config_jenkins_slave_url -OutFile $jenkinsDirectory\lib\slave.jar

# create artifacts that need to be shared with the other nodes.
mkdir -Force C:\vagrant\tmp | Out-Null
[IO.File]::WriteAllText(
    "C:\vagrant\tmp\$config_fqdn.ssh_known_hosts",
    (dir 'C:\ProgramData\ssh\ssh_host_*_key.pub' | %{ "$config_ip $(Get-Content $_)`n" }) -join ''
)

choco list -l
