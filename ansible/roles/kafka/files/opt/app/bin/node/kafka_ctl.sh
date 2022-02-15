#!/usr/bin/env bash

initNode() {
  log "INFO: Application is about to initialize . "
  ln -snf /opt/kafka/${KAFKA_SCALA_VERSION}-${KAFKA_VERSION} /opt/kafka/current  # default version 2.11
  _initNode
  if [ "$MY_ROLE" = "kafka-manager" ]; then
    echo 'ubuntu:kafka' | chpasswd;
    echo -e "client\nclient\n" | adduser client > /dev/nul 2>&1 || echo "client:client" | chpasswd;
    log "INFO: Application initialize password for client user. "
  fi
  mkdir -p ${DATA_MOUNTS}/log/zabbix/logs  ${DATA_MOUNTS}/log/$MY_ROLE/{dump,logs} ${DATA_MOUNTS}/$MY_ROLE/dump
  chown -R zabbix.zabbix ${DATA_MOUNTS}/log/zabbix
  chown -R kafka.kafka ${DATA_MOUNTS}/$MY_ROLE
  chown -R kafka.kafka ${DATA_MOUNTS}/log/$MY_ROLE
  chmod 777 ${DATA_MOUNTS}/log/$MY_ROLE
  ln -sf /opt/app/bin/node/kfkctl.sh  /usr/bin/kfkctl
  log "INFO: Application initialization completed  . "
}

start() {
  log "INFO: Application is asked to start . "
  _start || (log "ERROR: services failed to start  . " && return 1)
  if [ "$MY_ROLE" = "kafka-manager" ]; then
    local httpCode
    httpCode="$(retry 10 2 0 addCluster)" && [ "$httpCode" == "200" ] || log "Failed to add cluster automatically with '$httpCode'.";
    updateCluster || log "Failed to updateCluster when update";
  fi
  log "INFO: Application started successfully  . "
}

reload() {
  log "INFO: Application is asked to reload  . "
  _reload $@
  if [ "$MY_ROLE" == "kafka-manager" ]; then
    addCluster || log "Failed to addCluster when update";
    updateCluster || log "Failed to updateCluster when update";
  fi
  log "INFO: Application reloaded completely . "
}

check() {
  _check
  if [ "$MY_ROLE" = "kafka-manager" ]; then
    checkKafkaManager
  fi
}

measure() {
  local metrics; metrics=$(echo mntr | nc -u -q3 -w3 127.0.0.1 8125)
  [ -n "$metrics" ] || return 1

  cat << METRICS_EOF
  {
    "heap_usage": $(parseMetrics "$metrics" ".jvm.memory.heap.usage" 100),
    "MessagesInPerSec_1MinuteRate": $(parseMetrics "$metrics" ".kafka.server.BrokerTopicMetrics.MessagesInPerSec.1MinuteRate"),
    "BytesInPerSec_1MinuteRate": $(parseMetrics "$metrics" ".kafka.server.BrokerTopicMetrics.BytesInPerSec.1MinuteRate"),
    "BytesOutPerSec_1MinuteRate": $(parseMetrics "$metrics" ".kafka.server.BrokerTopicMetrics.BytesOutPerSec.1MinuteRate"),
    "Replica_MaxLag": $(parseMetrics "$metrics" "kafka.server.ReplicaFetcherManager.MaxLag.Replica"),
    "KafkaController_ActiveControllerCount": $(parseMetrics "$metrics" ".kafka.controller.KafkaController.ActiveControllerCount"),
    "KafkaController_OfflinePartitionsCount": $(parseMetrics "$metrics" ".kafka.controller.KafkaController.OfflinePartitionsCount")
  }
METRICS_EOF
}

parseMetrics() {
  local metrics="$1" key="$2" factor
  [ -z "$3" ] || factor="*$3"
  echo "$metrics" | xargs -n1 | awk -F: 'BEGIN{value=""} $1=="'$key'"{value=$2} END{print (value=="" ? 0 : value'$factor')}'
}

checkKafkaManager() {
  . /opt/app/bin/envs/appctl.env
  curl -u "${WEB_USER}:${WEB_PASSWORD}" "http://$MY_IP:$MY_PORT" | grep $CLUSTER_ID >> /dev/null
}

addCluster() {
  request "$(buildParams)" "http://$MY_IP:$MY_PORT/clusters"
}

updateCluster() {
  request "$(buildParams --update)" "http://$MY_IP:$MY_PORT/clusters/$CLUSTER_ID"
}

request() {
  curl -s -m5 -w '%{http_code}' -o /dev/null -u "$WEB_USER:$WEB_PASSWORD" $1 $2
}


buildParams() {
  local params="
  name=$CLUSTER_ID
  zkHosts=$ZK_HOSTS
  kafkaVersion=$KAFKA_VERSION_4_MANAGER
  jmxEnabled=true
  jmxUser=""
  jmxPass=""
  tuning.brokerViewUpdatePeriodSeconds=30
  tuning.clusterManagerThreadPoolSize=2
  tuning.clusterManagerThreadPoolQueueSize=100
  tuning.kafkaCommandThreadPoolSize=2
  tuning.kafkaCommandThreadPoolQueueSize=100
  tuning.logkafkaCommandThreadPoolSize=2
  tuning.logkafkaCommandThreadPoolQueueSize=100
  tuning.logkafkaUpdatePeriodSeconds=30
  tuning.partitionOffsetCacheTimeoutSecs=5
  tuning.brokerViewThreadPoolSize=2
  tuning.brokerViewThreadPoolQueueSize=1000
  tuning.offsetCacheThreadPoolSize=2
  tuning.offsetCacheThreadPoolQueueSize=1000
  tuning.kafkaAdminClientThreadPoolSize=2
  tuning.kafkaAdminClientThreadPoolQueueSize=1000
  tuning.kafkaManagedOffsetMetadataCheckMillis=30000
  tuning.kafkaManagedOffsetGroupCacheSize=1000000
  tuning.kafkaManagedOffsetGroupExpireDays=7
  securityProtocol=PLAINTEXT
  saslMechanism=DEFAULT
  jaasConfig=""
  "
  if [ "$1" == "--update" ]; then
    params="operation=Update $params"
  fi
  local p; for p in $params; do echo -n "--data-urlencode $p "; done
}

generate_and_sign_key() {
  pushd /ssl
  FQDN_NAME=$(hostname --fqdn)
  ROLE_NAME="server"
  if [ "$MY_ROLE" = "kafka-manager" ]; then
    ROLE_NAME="client"
  fi
  rm -f kafka.${ROLE_NAME}.* cert-file cert-signed
  keytool -genkey -keystore kafka.${ROLE_NAME}.keystore.jks -validity 365 -storepass "${SASL_PASSWD}" -keypass "${SASL_PASSWD}" -dname "CN=${FQDN_NAME}" -storetype pkcs12  -ext SAN=DNS:${FQDN_NAME}
  keytool -keystore kafka.${ROLE_NAME}.keystore.jks -certreq -file cert-file -storepass "${SASL_PASSWD}" -keypass "${SASL_PASSWD}"
  openssl x509 -req -CA ca-cert -CAkey ca-key -in cert-file -out cert-signed -days 365 -CAcreateserial -passin pass:"${SASL_PASSWD}"
  keytool -keystore kafka.${ROLE_NAME}.truststore.jks -alias CARoot -import -file ca-cert -storepass "${SASL_PASSWD}" -keypass "${SASL_PASSWD}" -noprompt
  keytool -keystore kafka.${ROLE_NAME}.keystore.jks -alias CARoot -import -file ca-cert -storepass "${SASL_PASSWD}" -keypass "${SASL_PASSWD}" -noprompt
  keytool -keystore kafka.${ROLE_NAME}.keystore.jks -import -file cert-signed -storepass "${SASL_PASSWD}" -keypass "${SASL_PASSWD}" -noprompt
  popd
}