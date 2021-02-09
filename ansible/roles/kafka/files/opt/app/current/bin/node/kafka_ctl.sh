#!/usr/bin/env bash

EC_UNCORDON_FAILED=100
EC_INSUFFICIENT_EIP=101
EC_DELETE_FIRST_NODE=102

initNode() {
  if [[  "${KAFKA_SCALA_VERSION}" == "2.11" ]]; then KAFKA_SCALA_VERSION="2.12"; fi
  ln -snf /opt/kafka/${KAFKA_SCALA_VERSION}-${KAFKA_VERSION} /opt/kafka/current  # default version 2.12
  _initNode
  if [ "$MY_ROLE" = "kafka-manager" ]; then echo 'root:kafka' | chpasswd; echo 'ubuntu:kafka' | chpasswd; fi
  mkdir -p /data/zabbix/logs  /data/$MY_ROLE/{dump,logs,ca}
  chown -R zabbix.zabbix /data/zabbix
  local htmlFile=/data/$MY_ROLE/index.html
  [ -e "$htmlFile" ] || ln -s /opt/app/current/conf/caddy/index.html $htmlFile
  ln -sf /opt/app/current/bin/node/kfkctl.sh  /usr/bin/kfkctl
  if [ "$MY_ROLE" == "kafka" ]; then
    retry 5 3 0 scpCaFromFirstNode
    [[ -f "/data/kafka/ca/ca-key" ]] || log "Failed to cp ca from first node"
    local json=$(jq -n --arg server_info ${MY_EIP:-${MY_IP}} --arg password qingcloud '{user_server_info:$server_info,cert_password:$password}')
    genCertForUserServer "$json"
  fi
  chown -R kafka.svc /data/$MY_ROLE
}

scpCaFromFirstNode(){
  local firstNode; for i in $KAFKA_NODES; do  [[ "$i" =~ "stable/kafka/1" ]] && firstNode="$i"; done ;
  if [[ ! "${firstNode}" =~ "${MY_INSTANCE_ID}" ]]; then
    log "copy ca from ${firstNode}"
    local firstNodeIp; firstNodeIp="$( echo ${firstNode} | awk -F/ '{print $6}')";
    for i in ca-key ca-cert; do
      curl -s -o /data/kafka/ca/${i} http://${firstNodeIp}/ca/${i}
    done
  fi
}

initCluster(){
  local firstNode; for i in $KAFKA_NODES; do  [[ "$i" =~ "stable/kafka/1" ]] && firstNode="$i"; done ;
  if [[ "${firstNode}" =~ "$MY_INSTANCE_ID" ]]; then
    local caStorePath="/data/kafka/ca"
    mkdir -p ${caStorePath};
    openssl req -new -newkey rsa:4096 -days 365 -x509 -subj "/CN=Kafka-Security-CA" -keyout ${caStorePath}/ca-key -out ${caStorePath}/ca-cert -nodes
    chown -R kafka.svc ${caStorePath};
    chmod 750 ${caStorePath}/*;
  fi
}

start() {
  _start
  if [ "$MY_ROLE" = "kafka-manager" ]; then
    local httpCode
    httpCode="$(retry 10 2 0 addCluster)" && [ "$httpCode" == "200" ] || log "Failed to add cluster automatically with '$httpCode'.";
    updateCluster || log "Failed to updateCluster when update";
  fi
}

reload() {
  if [ "$MY_ROLE" == "kafka" ]; then
    local json=$(jq -n --arg server_info ${MY_EIP:-${MY_IP}} --arg password qingcloud '{user_server_info:$server_info,cert_password:$password}')
    genCertForUserServer "$json"
  fi
  case "${1}" in
    kafka)
      local kafkaConfFile="/opt/app/current/conf/kafka/server.properties";
      if test -f ${kafkaConfFile}.1 && ! (diff -q  ${kafkaConfFile} ${kafkaConfFile}.1 ) ; then
        # only figure out the changed parameter
        _reload kafka;
      fi
      ;;
    caddy)
      local firstNode; for i in $KAFKA_NODES; do  [[ "$i" =~ "stable/kafka/1" ]] && firstNode="$i"; done ;
      if [[ "${JOINING_NODES}" =~ "kafka" ]] && [[ "${firstNode}" =~ "$MY_INSTANCE_ID" ]]; then
        # start caddy for transfer ca from first node to new node
        _startSvc caddy;
      else
        _reload caddy;
      fi
      ;;
    *)
      _reload $@ ;;
  esac
  if [ "$MY_ROLE" == "kafka-manager" ]; then
    addCluster || log "Failed to addCluster when update";
    updateCluster || log "Failed to updateCluster when update";
  fi
}

preCheckForScaleIn(){
  local firstNode; for i in $KAFKA_NODES; do  [[ "$i" =~ "stable/kafka/1" ]] && firstNode="$i"; done ;
  if [[ "${LEAVING_NODES}" =~ "${firstNode}" ]]; then
    exit $EC_DELETE_FIRST_NODE
  fi
}

scaleIn(){
  log "${LEAVING_NODES} deleted in $(date)."
}

scaleOut(){
  log "${JOINING_NODES} added in $(date)."
}

check() {
  _check
  if [[ "$MY_ROLE" = "kafka-manager" ]]; then
    checkKafkaManager
  fi
}

measure() {
  local metrics; metrics=$(echo mntr | nc -u -q3 -w3 127.0.0.1 8125)
  [[ -n "$metrics" ]] || return 1

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
  #. /opt/app/current/bin/envs/appctl.env
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

genCertForUserServer(){
  local server="$(echo $1 | jq -r .user_server_info)" certPwd="$(echo $1 | jq -r .cert_password)"
  local serverStorePath="/data/kafka/ssl/${server:-localhost}"
  local caStorePath="/data/kafka/ca"
  mkdir -p ${serverStorePath}
  rm -rf ${serverStorePath}/* # in case user change password
  echo "ssl.truststore.location --->  ${server:-localhost}/kafka.server.truststore.jks ;  ssl.truststore.password ---> ${certPwd:-qingcloud} " > /data/kafka/ssl/${server:-localhost}/README
  keytool -keystore ${serverStorePath}/kafka.server.keystore.jks -alias ${server:-localhost} -validity 3650  -genkey -keyalg RSA -ext SAN=DNS:${server} -storepass "${certPwd:-qingcloud}" -keypass "${certPwd:-qingcloud}"  -storetype pkcs12 -dname "CN=${server:-localhost}"
  keytool -keystore ${serverStorePath}/kafka.server.truststore.jks  -alias CARoot -importcert -file ${caStorePath}/ca-cert  -storepass ${certPwd:-qingcloud} -keypass ${certPwd:-qingcloud} -noprompt
  keytool -keystore ${serverStorePath}/kafka.server.keystore.jks -alias ${server:-localhost} -certreq -file ${serverStorePath}/server-cert-request-file -storepass ${certPwd:-qingcloud} -keypass ${certPwd:-qingcloud}
  openssl x509 -req -CA ${caStorePath}/ca-cert -CAkey ${caStorePath}/ca-key -in ${serverStorePath}/server-cert-request-file -out ${serverStorePath}/server-cert-request-signed-file -days 3650 -CAcreateserial -passin pass:${certPwd:-qingcloud}
  keytool -keystore ${serverStorePath}/kafka.server.keystore.jks -alias CARoot -importcert -file ${caStorePath}/ca-cert -storepass ${certPwd:-qingcloud} -keypass ${certPwd:-qingcloud} -noprompt
  keytool -keystore ${serverStorePath}/kafka.server.keystore.jks -alias ${server:-localhost}  -importcert -file ${serverStorePath}/server-cert-request-signed-file -storepass ${certPwd:-qingcloud} -keypass ${certPwd:-qingcloud} -noprompt
  chmod -R 750 ${serverStorePath}
  chown -R kafka.svc /data/$MY_ROLE
}
