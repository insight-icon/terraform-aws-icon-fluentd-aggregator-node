#!/bin/bash
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
set -e

export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get upgrade -y
apt-get install -y linux-aws
apt-get install -y awscli
apt install python -y
apt install python-apt -y

EC2_INSTANCE_ID=$(wget -q -O - http://169.254.169.254/latest/meta-data/instance-id || die \"wget instance-id has failed: $?\")
EC2_AVAIL_ZONE=$(wget -q -O - http://169.254.169.254/latest/meta-data/placement/availability-zone || die \"wget availability-zone has failed: $?\")
EC2_REGION="`echo \"$EC2_AVAIL_ZONE\" | sed -e 's:\([0-9][0-9]*\)[a-z]*\$:\\1:'`"

# Install docker
apt-get install -y apt-transport-https ca-certificates curl software-properties-common
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
add-apt-repository \
   "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
   $(lsb_release -cs) \
   stable"
apt-get install -y docker-ce
usermod -aG docker ubuntu

# Install docker-compose
curl -L https://github.com/docker/compose/releases/download/1.21.0/docker-compose-$(uname -s)-$(uname -m) -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

echo $'{\n    "experimental": true,\n    "metrics-addr": "0.0.0.0:9323"\n}' | sudo tee /etc/docker/daemon.json;
systemctl restart docker

## Prometheus setup
# Set node exporter version
# Either pin to latest
#NODE_EXPORTER_VERSION='latest'
# Or pin a specific release
# NOTE: "latest" doensn't seem to work :/
NODE_EXPORTER_VERSION='0.18.1'

useradd -m -s /bin/bash prometheus

curl -L -O  https://github.com/prometheus/node_exporter/releases/download/v$NODE_EXPORTER_VERSION/node_exporter-$NODE_EXPORTER_VERSION.linux-amd64.tar.gz

tar -xzvf node_exporter-$NODE_EXPORTER_VERSION.linux-amd64.tar.gz
mv node_exporter-$NODE_EXPORTER_VERSION.linux-amd64 /home/prometheus/node_exporter
rm node_exporter-$NODE_EXPORTER_VERSION.linux-amd64.tar.gz
chown -R prometheus:prometheus /home/prometheus/node_exporter

# Add node_exporter as systemd service
tee -a /etc/systemd/system/node_exporter.service << NODEEXPEND
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target
[Service]
User=prometheus
ExecStart=/home/prometheus/node_exporter/node_exporter
[Install]
WantedBy=default.target
NODEEXPEND

systemctl daemon-reload
systemctl start node_exporter
systemctl enable node_exporter

## Consul setup
apt-get install -y unzip
curl --silent --remote-name https://releases.hashicorp.com/consul/1.6.1/consul_1.6.1_linux_amd64.zip
unzip consul_1.6.1_linux_amd64.zip
chown root:root consul
mv consul /usr/local/bin/
useradd --system --home /etc/consul.d --shell /bin/false consul
mkdir --parents /opt/consul
chown --recursive consul:consul /opt/consul
PRIVIP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4/)
tee -a /etc/systemd/system/consul.service << CONSULSVCEND
[Unit]
Requires=network-online.target
After=network-online.target
ConditionFileNotEmpty=/etc/consul.d/consul.hcl

[Service]
User=consul
Group=consul
ExecStart=/usr/local/bin/consul agent -config-file=/etc/consul.d/consul.hcl -retry-join="provider=aws tag_key=consul-servers tag_value=auto-join addr_type=private_v4"
ExecReload=/bin/kill -HUP $MAINPID
KillSignal=SIGINT
TimeoutStopSec=5
Restart=on-failure
SyslogIdentifier=consul

[Install]
WantedBy=multi-user.target
CONSULSVCEND

mkdir --parents /etc/consul.d
tee -a /etc/consul.d/consul.hcl << CONSULHCLEND
{
"bind_addr": "$PRIVIP",
"datacenter": "us-east-1",
"data_dir": "/opt/consul",
"server": false
"retry_join": ["provider=aws tag_key=consul-servers tag_value=auto-join addr_type=private_v4"]
}
CONSULHCLEND

chown --recursive consul:consul /etc/consul.d
chmod 640 /etc/consul.d/consul.hcl

systemctl enable consul
systemctl start consul

tee -a /home/ubuntu/host-node-exporter-payload.json << HOSTNODEPAYLOAD
{
  "service": {
    "ID": "host_$EC2_INSTANCE_ID",
    "Name": "fluentd_node_exporter",
    "Tags": [
      "citizen"
    ],
    "Address": "$PRIVIP",
    "Port": 9100,
    "Check": {
      "DeregisterCriticalServiceAfter": "60m",
      "id": "prometheus-api",
      "name": "HTTP on port 9100",
      "http": "http://$PRIVIP:9100",
      "interval": "10s",
      "timeout": "1s"
    }
  }
}
HOSTNODEPAYLOAD

tee -a /home/ubuntu/docker-node-exporter-payload.json << DOCKERHOSTPAYLOAD
{
  "service": {
    "ID": "docker_$EC2_INSTANCE_ID",
    "Name": "fluentd_node_exporter",
    "Tags": [
      "citizen"
    ],
    "Address": "$PRIVIP",
    "Port": 9323,
    "Check": {
      "DeregisterCriticalServiceAfter": "60m",
      "id": "prometheus-api",
      "name": "HTTP on port 9323",
      "http": "http://$PRIVIP:9323/metrics",
      "interval": "10s",
      "timeout": "1s"
    }
  }
}
DOCKERHOSTPAYLOAD

tee -a /home/ubuntu/fluentd-exporter-payload.json << FLUENTDAGG
{
  "service": {
    "ID": "fluentd_$EC2_INSTANCE_ID",
    "Name": "fluentd",
    "Address": "$PRIVIP",
    "Port": 24224
  }
}
FLUENTDAGG

consul services register /home/ubuntu/host-node-exporter-payload.json
consul services register /home/ubuntu/docker-node-exporter-payload.json
consul services register /home/ubuntu/fluentd-exporter-payload.json

tee -a /home/ubuntu/docker-compose.yaml << DOCKERYAMLEND
version: '3'
services:
   loop-logger:
      image: looploy/fluentd
      container_name: loop_logger
      restart: always
      network_mode: host
      volumes:
         - ./fluent/log:/fluentd/log
      environment:
         FLUENTD_MODE: server
         FLUENTD_MATCH_ELA_HOST: es.us-east-1.aws.patchnotes.xyz
DOCKERYAMLEND

/usr/local/bin/docker-compose -f /home/ubuntu/docker-compose.yaml up -d