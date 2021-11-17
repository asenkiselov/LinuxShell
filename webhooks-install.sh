#!/usr/bin/env bash

# Script:
# - requires root privileges
# - installs necessary dependencies
# - generates keys and certificate needed to secure webhooks communicaiton
# - creates a Linux service that is used for running the webhook

### helper funcitons

info () {
  local MESSAGE=$1
  local PREFIX=${2:-"INFO"}
  echo -e "${PREFIX}: ${MESSAGE} \e[0m"
}

warn () {
  local MESSAGE=$1
  local PREFIX=${2:-"WARN"}
  echo -e "\e[1;33m${PREFIX}: ${MESSAGE} \e[0m"
}

error () {
  local MESSAGE=$1
  local PREFIX=${2:-"ERROR"}
  echo -e "\e[1;31m${PREFIX}: ${MESSAGE} \e[0m"
}

### main

# if no parameters are provided
if [ $# -eq 0 ]; then
    warn "Usage: $(basename "$0") <service-name> (<port>)"
    exit 1
fi

SERVICE_NAME=${1}
WEBHOOK_PORT=${2:-1551}
WORKDIR=$(dirname $(readlink -f "$0"))


info "Check required files are present... Working directory is ${WORKDIR}."
if [ ! -f ${WORKDIR}/hooks.json ] || [ ! -f /root/.env ] || [ ! -f ${WORKDIR}/stack.sh ] ; then
    error "Required files not found!"
    exit 1
fi


info "Check port ${WEBHOOK_PORT} is free"
if lsof -Pi :${WEBHOOK_PORT} -sTCP:LISTEN -t >/dev/null ; then
    error "Port ${WEBHOOK_PORT} is in use"
    exit 1
fi
    
info "Check webhook executable it is in the correct path"
if [ ! -x "$(command -v webhook)" ]; then
    ### Automatically fetch the latest version, not recommended
    # VERSION=$(curl -s https://github.com/adnanh/webhook/releases/latest/download 2>&1 | grep -Po [0-9]+\.[0-9]+\.[0-9]+)
    warn "Install webhook executable..."
    VERSION="2.8.0"
    curl -sSL "https://github.com/adnanh/webhook/releases/download/${VERSION}/webhook-linux-amd64.tar.gz" -o /tmp/webhook-${VERSION}.tgz
    rm -rf /tmp/webhook-${VERSION}
    mkdir /tmp/webhook-${VERSION}
    tar xvf /tmp/webhook-${VERSION}.tgz --directory /tmp/webhook-${VERSION}
    mv /tmp/webhook-${VERSION}/webhook-linux-amd64/webhook /usr/local/bin/webhook
    chmod +x /usr/local/bin/webhook
fi


info "Generating key and certificate"
if [ ! -f ${WORKDIR}/key.pem ] || [ ! -f ${WORKDIR}/cert.pem ] ; then
    rm key.pem cert.pem 2> /dev/null
   
    openssl genrsa -out $WORKDIR/key.pem 2048
    openssl req -new -x509 -days 3650 -subj "/C=BG/ST=Sofia/L=Sofia/O=NRA/OU=DevOps/CN=$(hostname -I|cut -d" " -f 1)" \
        -key $WORKDIR/key.pem \
        -out $WORKDIR/cert.pem
else
	warn "Key/cert already exists"
fi


info "Generate hooks config file"
# webhook does not support environment variables so we manually substitute them
export ENV_WORKDIR=${WORKDIR}

info "Import environment-specific configuration"
source /root/.env
export $(grep "\S" /root/.env | grep -v "#" | cut -d= -f1) # export variables from file ignoring comments and blank lines

envsubst < ${WORKDIR}/hooks.json > ${WORKDIR}/hooks-generated.json


info "Making the systemd entries for service 'nra-webhook-${SERVICE_NAME}'"
cat > /etc/systemd/system/nra-webhook-${SERVICE_NAME}.service << EOF
[Unit]
Description=NRA Webhook service for ${SERVICE_NAME}
ConditionPathExists=/usr/local/bin/webhook
ConditionPathExists=${WORKDIR}
After=network.target

[Service]
Type=simple
User=root
Group=root
LimitNOFILE=1024

Restart=on-failure
RestartSec=10

WorkingDirectory=${WORKDIR}
ExecStart=/usr/local/bin/webhook -cert ${WORKDIR}/cert.pem -key ${WORKDIR}/key.pem -port ${WEBHOOK_PORT} -hooks ${WORKDIR}/hooks-generated.json -verbose -template -secure -hotreload

[Install]
WantedBy=multi-user.target

EOF

# start the service
systemctl daemon-reload
systemctl start nra-webhook-${SERVICE_NAME}
systemctl enable --now nra-webhook-${SERVICE_NAME}
