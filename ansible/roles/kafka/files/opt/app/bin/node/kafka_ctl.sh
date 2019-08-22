#!/usr/bin/env bash

init() {
  _init
  if [ "$MY_ROLE" = "kafka-manager" ]; then echo 'root:kafka' | chpasswd; echo 'ubuntu:kafka' | chpasswd; fi
  mkdir -p /data/zabbix/logs  /data/$MY_ROLE/{dump,logs}
  touch    /data/zabbix/logs/zabbix_agentd.log
  chown -R zabbix.zabbix /data/zabbix
  chown -R kafka.kafka /data/$MY_ROLE  
  local htmlFile=/data/$MY_ROLE/index.html
  [ -e "$htmlFile" ] || ln -s /opt/app/conf/caddy/index.html $htmlFile
}


start() {
  _start
  if [ "$MY_ROLE" = "kafka-manager" ]; then
    local httpCode
    httpCode="$(retry 10 2 0 addCluster)" && [ "$httpCode" == "200" ] || log "Failed to add cluster automatically with '$httpCode'."
  fi
}

update() {
  _update $@
  if [ "$MY_ROLE" == "kafka-manager" ]; then
    addCluster; updateCluster
  fi
}

check() {
  _check
  if [ "$MY_ROLE" = "kafka-manager" ] && [ "$KAFKA_NUM" -gt "0" ]; then
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
  curl "http://$MY_IP:$MY_PORT" | grep $CLUSTER_ID >> /dev/null
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
  kafkaVersion=$KAFKA_VERSION
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