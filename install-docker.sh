#!/bin/bash

#####################################
# Script for provisioning a Docker VM
#####################################

# Steps:
# - Install & configure docker
# - Create docker user
# - Setup cleanup of Docker artifacts
# - Configure HTTP proxy
# - Open firewall ports
# - Disable IPv6
# - Configure container time


# if no parameters are provided
if [ $# -eq 0 ]; then
    echo "Usage: $(basename "$0") <registry-address> <registry-token> <swarm-node-type> <deployment> (<docker-user-password>) (<http-proxy>)"
    echo " - registry-address: Address of Docker Registry (e.g. ro30dockerregistry.tax.minfin.bg:8086)"
    echo " - registry-token:   Token for authenticating to the Docker Registry. Contains base64 encoded 'user:password' (e.g. 'dXNlcjpwYXNzd2')"
    echo " - swarm-node-type:  Choose Docker Swarm node type (worker, manager, none)"
    echo " - deployment:       Choose which deployment is being setup (es, soa, logging)"
    echo " - docker-user-password (optional) Password for docker user. Needed only if an additional user is required."
	  echo " - http-proxy:       (optional) Proxy for acessing the Internet (e.g. http://10.22.122.14:8080). Needed only on specific nodes!"
    exit 1
fi

# Load parameters. See help message for details.
REGISTRY_ADDRESS=$1
REGISTRY_TOKEN=$2      
SWARM_NODE_TYPE=$3
DEPLOYMENT=$4
DOCKER_USER="docker"
DOCKER_USER_PASSWORD=$5
HTTP_PROXY=$6
# Define new location for Docker
DOCKER_INSTALL_DIR="/u01"


############################
# Install & configure docker
############################

echo "Install Latest Stable Docker Release & useful utils"

# for linux utils
SUSEConnect -p sle-module-basesystem/15.1/x86_64
# for docker utils
SUSEConnect -p sle-module-containers/15.1/x86_64
# for docker-compose
SUSEConnect -p sle-module-python2/15.1/x86_64

zypper -n update
zypper -n refresh
zypper install -y docker libreadline7 jq
zypper clean
systemctl enable docker

echo "Configure authentication to Docker Registry"
mkdir -pv ~/.docker

tee ~/.docker/config.json >/dev/null <<EOF
{
        "auths": {
                "${REGISTRY_ADDRESS}": {
                        "auth": "${REGISTRY_TOKEN}"
                }
        },
        "HttpHeaders": {
                "User-Agent": "Docker-Client/19.03.11 (linux)"
        }
}
EOF

echo "Configure Docker daemon"

if [[ -d $DOCKER_INSTALL_DIR ]]
then
   
  # Internal registry must be added so Docker can download application images
  # Experimental flag is enabled so monitoring works
  # TODO: Consider enabling FluentD by default if NRA's logging infrastructure can take Docker's logs
  tee /etc/docker/daemon.json >/dev/null <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "insecure-registries" : ["${REGISTRY_ADDRESS}","0.0.0.0/0"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2",
  "metrics-addr": "127.0.0.1:9323",
  "experimental": true,
  "data-root": "${DOCKER_INSTALL_DIR}/docker/lib/"
}
EOF

  echo "Move all docker config files to $DOCKER_INSTALL_DIR"

  mkdir -pv $DOCKER_INSTALL_DIR/docker/lib $DOCKER_INSTALL_DIR/docker/etc/sysconfig $DOCKER_INSTALL_DIR/docker/etc/docker 

  # Is config file already a symlink?
  if [[ -h  ~/.docker/config.json ]] 
  then
    echo "Docker is already moved."  
  else 
    mv -v /etc/sysconfig/docker $DOCKER_INSTALL_DIR/docker/etc/sysconfig/
    mv -v /etc/docker/* $DOCKER_INSTALL_DIR/docker/etc/docker/
    mv -v ~/.docker/config.json $DOCKER_INSTALL_DIR/docker/
  
    ln -sv $DOCKER_INSTALL_DIR/docker/etc/sysconfig/docker /etc/sysconfig/
    ln -sv $DOCKER_INSTALL_DIR/docker/etc/docker/* /etc/docker/
    ln -sv $DOCKER_INSTALL_DIR/docker/config.json ~/.docker/
  fi

else
  echo "Directory $DOCKER_INSTALL_DIR does not exist! Docker installation will not be moved."
  # "no-new-privileges": false ( Restrict containers from acquiring additional privileges via suid or sgid)
  #  "icc": false   ( network traffic is restricted between containers on the default bridge)
  tee /etc/docker/daemon.json >/dev/null <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "insecure-registries" : ["${REGISTRY_ADDRESS}","0.0.0.0/0"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2",
  "metrics-addr": "127.0.0.1:9323",
  "experimental": true,
  "no-new-privileges": false,
  "icc": false
}
EOF
fi


######################################
# Periodic cleanup of Docker artifacts
######################################

echo "Configure periodic cleanup of Docker artifacts"

# Every day, after midnight at (01:00, 02:00, 03:00) 
crontab << EOF
0 1 * * * docker container prune -f
0 2 * * * docker image prune -fa
0 3 * * * docker volume prune -f
EOF


######################
# Configure HTTP proxy
######################

if [ -z "$HTTP_PROXY" ]; then
  echo "Skip HTTP Proxy config"
else
  echo "Configure HTTP Proxy"
  tee /etc/sysconfig/docker >/dev/null <<EOF
## Path           : System/Management
## Description    : Extra cli switches for docker daemon
## Type           : string
## Default        : ""
## ServiceRestart : docker
#
DOCKER_OPTS=""
HTTP_PROXY="${HTTP_PROXY}"
HTTPS_PROXY="${HTTP_PROXY}"
NO_PROXY="*.tax.minfin.bg,*.nra.bg"
EOF
fi


##############
# Start docker
##############

echo "Start docker service and reload docker daemon"

systemctl daemon-reload
systemctl restart docker


####################
# Create docker user
####################

echo "Create user to manage Docker as a non-root user"

if [ -z "$DOCKER_USER" ] || [ -z "$DOCKER_USER_PASSWORD" ]
then
  echo "Skip Docker user config"
else
  cat /etc/passwd | grep -w ^$DOCKER_USER >/dev/null 2>&1
  if [ $? -eq 0 ] ; then
    echo "$DOCKER_USER already exists"
  else
     useradd -p $(openssl passwd -1 $DOCKER_USER_PASSWORD) -s /bin/bash -g docker -m $DOCKER_USER
     mkdir -p /home/$DOCKER_USER/.docker
     cp /u01/docker/config.json /home/"$DOCKER_USER"/.docker/
     ID=$(id -u "$DOCKER_USER")
     chown "$ID":"$ID" /home/"$DOCKER_USER"/.docker -R
     chmod g+rwx "/home/$DOCKER_USER/.docker" -R
  fi
fi


#####################
# Open firewall ports
#####################

echo "Open firewall ports via iptables"
# Firewalls usually flush iptables and affect Docker's own rules.
# Therefore, we define iptables rules in a separate chain (FILTERS) and chain it to the INPUT & DOCKER-USER chains.
# Only these chains are flushed explicitly to avoid deleting Docker's rules in FORWARD chain and other Docker-specific chains.
# See https://unrouted.io/2017/08/15/docker-firewall/ for details.

IPTABLES_CONFIG=/u01/iptables.conf

tee $IPTABLES_CONFIG > /dev/null <<EOF
*filter
:INPUT ACCEPT [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]
:FILTERS - [0:0]
:DOCKER-USER - [0:0]

# Flush chains
-F INPUT
-F DOCKER-USER
-F FILTERS

# Allow common traffic
-A INPUT -i lo -j ACCEPT
-A INPUT -p icmp --icmp-type any -j ACCEPT

# Chain to filters
-A INPUT -j FILTERS
-A DOCKER-USER -i eth0 -j FILTERS

-A FILTERS -m state --state ESTABLISHED,RELATED -j ACCEPT
-A FILTERS -m state --state NEW -m tcp -p tcp --dport 22 -j ACCEPT
EOF

echo "Open firewall ports for this specific Deployment: $DEPLOYMENT"

if [ "$DEPLOYMENT" = "soa" ] || [ "$DEPLOYMENT" = "es" ]; then
  echo "Open firewall ports for Monitoring" 
  echo "-A FILTERS -m state --state NEW -m tcp -p tcp --dport 1090 -j ACCEPT" >> $IPTABLES_CONFIG 
  echo "-A FILTERS -m state --state NEW -m tcp -p tcp --dport 3000 -j ACCEPT" >> $IPTABLES_CONFIG 
  echo "-A FILTERS -m state --state NEW -m tcp -p tcp --dport 9093 -j ACCEPT" >> $IPTABLES_CONFIG 
  echo "-A FILTERS -m state --state NEW -m tcp -p tcp --dport 9100 -j ACCEPT" >> $IPTABLES_CONFIG 
  echo "Open firewall ports for Spring Boot Admin" 
  echo "-A FILTERS -m state --state NEW -m tcp -p tcp --dport 1111 -j ACCEPT" >> $IPTABLES_CONFIG 
fi
  
if [ "$DEPLOYMENT" = "soa" ]; then
  # SOA API GW
  echo "-A FILTERS -m state --state NEW -m tcp -p tcp --dport 9443 -j ACCEPT" >> $IPTABLES_CONFIG 
elif [ "$DEPLOYMENT" = "es" ]; then
  # ES API GW 
  echo "-A FILTERS -m state --state NEW -m tcp -p tcp --dport 8443 -j ACCEPT" >> $IPTABLES_CONFIG
  # ES Auth GW
  echo "-A FILTERS -m state --state NEW -m tcp -p tcp --dport 8088 -j ACCEPT" >> $IPTABLES_CONFIG
  # ES Base API
  echo "-A FILTERS -m state --state NEW -m tcp -p tcp --dport 8080 -j ACCEPT" >> $IPTABLES_CONFIG
  # ES Public & Partners static resources
  echo "-A FILTERS -m state --state NEW -m tcp -p tcp --dport 9010 -j ACCEPT" >> $IPTABLES_CONFIG
  echo "-A FILTERS -m state --state NEW -m tcp -p tcp --dport 9011 -j ACCEPT" >> $IPTABLES_CONFIG
elif [ "$DEPLOYMENT" = "logging" ]; then
  # Kibana UI
  echo "-A FILTERS -m state --state NEW -m tcp -p tcp --dport 5601 -j ACCEPT" >> $IPTABLES_CONFIG
  # ElasticSearch API
  echo "-A FILTERS -m state --state NEW -m tcp -p tcp --dport 9200 -j ACCEPT" >> $IPTABLES_CONFIG
  # FluentBit sink
  echo "-A FILTERS -m state --state NEW -m tcp -p tcp --dport 24224 -j ACCEPT" >> $IPTABLES_CONFIG      
fi

echo "Open firewall ports for Docker Swarm Node: $SWARM_NODE_TYPE"

if [ "$SWARM_NODE_TYPE" = "manager" ] || [ "$SWARM_NODE_TYPE" = "worker" ]; then
  # Required ports for Docker Swarm (all nodes)
  echo "-A FILTERS -m state --state NEW -m tcp -p tcp --dport 7946 -j ACCEPT" >> $IPTABLES_CONFIG
  echo "-A FILTERS -m state --state NEW -m udp -p udp --dport 7946 -j ACCEPT" >> $IPTABLES_CONFIG
  echo "-A FILTERS -m state --state NEW -m udp -p udp --dport 4789 -j ACCEPT" >> $IPTABLES_CONFIG
fi

if [ "$SWARM_NODE_TYPE" = "manager" ]; then
  # Required ports for Docker Swarm
  echo "-A FILTERS -m state --state NEW -m tcp -p tcp --dport 2377 -j ACCEPT" >> $IPTABLES_CONFIG 
  
  # Allow connections to Swarm UI only from localhost
  echo "-A FILTERS -m state --state NEW -m tcp -p tcp -s localhost --dport 9000 -j ACCEPT" >> $IPTABLES_CONFIG 

  # Allow connection to WebHook for deliveries
  echo "-A FILTERS -m state --state NEW -m tcp -p tcp --dport 1551 -j ACCEPT" >> $IPTABLES_CONFIG 
elif [ "$SWARM_NODE_TYPE" = "worker" ]; then
  #  overlay network with encryption  ip protocol 50 (ESP) traffic is allowed.
  echo "-A FILTERS -m state --state NEW -m tcp -p tcp --dport 50 -j ACCEPT" >> $IPTABLES_CONFIG
  # Add worker specific ports here
fi  

# Close config file (log & reject rules)
echo "-A FILTERS -m limit --limit 5/min -j LOG --log-prefix iptables_FILTERS_denied: --log-level 7" >> $IPTABLES_CONFIG
echo "-A FILTERS -j REJECT --reject-with icmp-host-prohibited" >> $IPTABLES_CONFIG
echo "COMMIT" >> $IPTABLES_CONFIG

echo "Create OS service to maintain custom iptables"

# Make sure iptables are loaded via "-n" to avoid flushing all chains
tee /etc/systemd/system/iptables.service > /dev/null <<EOF
[Unit]
Description=Restore iptables firewall rules
Before=network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/iptables-restore -n ${IPTABLES_CONFIG}

[Install]
WantedBy=multi-user.target
EOF

systemctl enable iptables
systemctl start iptables


##############
# Disable IPv6
##############

echo "Disable ipv6 from host OS"
tee /etc/sysctl.conf > /dev/null <<EOF
####
#
# /etc/sysctl.conf is meant for local sysctl settings
#
# sysctl reads settings from the following locations:
#   /boot/sysctl.conf-<kernelversion>
#   /lib/sysctl.d/*.conf
#   /usr/lib/sysctl.d/*.conf
#   /usr/local/lib/sysctl.d/*.conf
#   /etc/sysctl.d/*.conf
#   /run/sysctl.d/*.conf
#   /etc/sysctl.conf
#
# To disable or override a distribution provided file just place a
# file with the same name in /etc/sysctl.d/
#
# See sysctl.conf(5), sysctl.d(5) and sysctl(8) for more information
#
####

net.ipv4.ip_forward = 0
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
vm.max_map_count=262144

EOF

echo "Reload the options sysctl -p"
sysctl -p 


######################################
# Configure time for docker containers
######################################
unlink /etc/localtime
ln -s /usr/share/zoneinfo/Europe/Sofia /etc/localtime
echo "Europe/Sofia"> /etc/timezone    


#####
# End
#####

exit 0
