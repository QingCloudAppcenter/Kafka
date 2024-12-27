#!/usr/bin/env bash

initNode() {
  log "INFO: Application is about to initialize . "
  _initNode
  chmod 755 ${DATA_MOUNTS}/log # kylin: sometimes 700
  if [ "$MY_ROLE" = "kafka-manager" ]; then
    adduser client > /dev/nul 2>&1 || :
    echo "client:p@33w0rd" | chpasswd || :
    log "INFO: Application initialize password for client user. "
  fi

  if [ "${SASL}" = "SCRAM-SHA-256" ] || [ "${SASL}" = "SCRAM-SHA-512" ]; then
    retry_create_zk_node
  fi

  mkdir -p ${DATA_MOUNTS}/log/zabbix/logs  ${DATA_MOUNTS}/log/$MY_ROLE/{dump,logs} ${DATA_MOUNTS}/$MY_ROLE/dump
  mkdir -p /etc/zabbix/zabbix_agentd.d/
  chown -R zabbix.zabbix ${DATA_MOUNTS}/log/zabbix
  chown -R kafka.kafka ${DATA_MOUNTS}/$MY_ROLE
  chown -R kafka.kafka ${DATA_MOUNTS}/log/$MY_ROLE
  chmod 777 ${DATA_MOUNTS}/log/$MY_ROLE
  ln -sf /opt/app/bin/node/kfkctl.sh  /usr/bin/kfkctl
  touch /opt/app/conf/appctl/kafka.metrics
  log "INFO: Application initialization completed  . "
}

upgradeInit() {
  _initNode
  mkdir -p ${DATA_MOUNTS}/log/zabbix/logs ${DATA_MOUNTS}/log/$MY_ROLE/{dump,logs} ${DATA_MOUNTS}/$MY_ROLE/dump
  chown -R syslog:adm ${DATA_MOUNTS}/log/appctl
  chown syslog:syslog ${DATA_MOUNTS}/log/journald/*
  chown -R kafka:kafka ${DATA_MOUNTS}/$MY_ROLE
  chown -R kafka:kafka ${DATA_MOUNTS}/log/$MY_ROLE
  chown -R zabbix:zabbix ${DATA_MOUNTS}/log/zabbix
  ln -sf /opt/app/bin/node/kfkctl.sh  /usr/bin/kfkctl
  touch /opt/app/conf/appctl/kafka.metrics
  systemctl restart rsyslog
}


CURRENT_LMFV="3.0"
KAFKA_PROPERTIES_FILE=/opt/app/conf/kafka/server.properties
start() {
  if [ "$UPGRADING_FLAG" = "true" ]; then
    upgradeInit
    if [ "$MY_ROLE" = "kafka" ]; then
      log "INFO: upgrading from $OLD_IBPV"
      log "INFO: set inter.broker.protocol.version to $OLD_IBPV"
      if grep -q '^inter\.broker\.protocol\.version' $KAFKA_PROPERTIES_FILE; then
        sed -i "s/^inter\.broker\.protocol\.version=.*/inter.broker.protocol.version=$OLD_IBPV/" $KAFKA_PROPERTIES_FILE
      else
        echo "inter.broker.protocol.version=$OLD_IBPV" >> $KAFKA_PROPERTIES_FILE
      fi
      if [ "$CURRENT_LMFV" != "$OLD_LMFV" ]; then
        log "INFO: set log.message.format.version to $OLD_LMFV"
        if grep -q '^log\.message\.format\.version' $KAFKA_PROPERTIES_FILE; then
          sed -i "s/^log\.message\.format\.version=.*/log.message.format.version=$OLD_LMFV/" $KAFKA_PROPERTIES_FILE
        else
          echo "log.message.format.version=$OLD_LMFV" >> $KAFKA_PROPERTIES_FILE
        fi
      fi
    fi
  fi
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

#  parseMetricsForJmx "server" "BrokerTopicMetrics" "MessagesInPerSec" "OneMinuteRate" "MessagesInPerSec_1MinuteRate" &
#  parseMetricsForJmx "server" "BrokerTopicMetrics" "BytesInPerSec" "OneMinuteRate" "BytesInPerSec_1MinuteRate" &
#  parseMetricsForJmx "server" "BrokerTopicMetrics" "BytesOutPerSec" "OneMinuteRate" "BytesOutPerSec_1MinuteRate" &
#  parseMetricsForJmx "server" "ReplicaFetcherManager" "MaxLag,clientId=Replica" "Value" "Replica_MaxLag" &
#  parseMetricsForJmx "server" "ReplicaManager" "IsrExpandsPerSec" "OneMinuteRate" "IsrExpandsPerSec_1MinuteRate" &
#  parseMetricsForJmx "controller" "KafkaController" "ActiveControllerCount" "Value" "KafkaController_ActiveControllerCount" &
#  parseMetricsForJmx "controller" "KafkaController" "OfflinePartitionsCount" "Value" "KafkaController_OfflinePartitionsCount" &
#  wait

  cat << METRICS_EOF
  {
    "heap_usage": $(parseMetrics "$metrics" ".jvm.memory.heap.usage" 100),
    "MessagesInPerSec_1MinuteRate": $(cat /opt/app/conf/appctl/kafka.metrics | grep MessagesInPerSec | grep OneMinuteRate | awk '{printf("%.f",$2)}'),
    "BytesInPerSec_1MinuteRate": $(cat /opt/app/conf/appctl/kafka.metrics | grep BytesInPerSec | grep OneMinuteRate | awk '{printf("%.f",$2)}'),
    "BytesOutPerSec_1MinuteRate": $(cat /opt/app/conf/appctl/kafka.metrics | grep BytesOutPerSec | grep OneMinuteRate | awk '{printf("%.f",$2)}'),
    "Replica_MaxLag": $(cat /opt/app/conf/appctl/kafka.metrics | grep ReplicaFetcherManager | grep Value | awk '{printf("%.f",$2)}'),
    "IsrExpandsPerSec_1MinuteRate": $(cat /opt/app/conf/appctl/kafka.metrics | grep IsrExpandsPerSec | grep OneMinuteRate | awk '{printf("%.f",$2)}'),
    "KafkaController_ActiveControllerCount": $(cat /opt/app/conf/appctl/kafka.metrics | grep ActiveControllerCount | grep Value | awk '{printf("%.f",$2)}'),
    "KafkaController_OfflinePartitionsCount": $(cat /opt/app/conf/appctl/kafka.metrics | grep OfflinePartitionsCount | grep Value | awk '{printf("%.f",$2)}')
  }
METRICS_EOF
  parseMetricsForJmxAll &

#  cat << METRICS_EOF
#  {
#    "heap_usage": $(parseMetrics "$metrics" ".jvm.memory.heap.usage" 100),
#    "MessagesInPerSec_1MinuteRate": $(cat /opt/app/conf/appctl/MessagesInPerSec_1MinuteRate.metrics),
#    "BytesInPerSec_1MinuteRate": $(cat /opt/app/conf/appctl/BytesInPerSec_1MinuteRate.metrics),
#    "BytesOutPerSec_1MinuteRate": $(cat /opt/app/conf/appctl/BytesOutPerSec_1MinuteRate.metrics),
#    "Replica_MaxLag": $(cat /opt/app/conf/appctl/Replica_MaxLag.metrics),
#    "IsrExpandsPerSec_1MinuteRate": $(cat /opt/app/conf/appctl/IsrExpandsPerSec_1MinuteRate.metrics),
#    "KafkaController_ActiveControllerCount": $(cat /opt/app/conf/appctl/KafkaController_ActiveControllerCount.metrics),
#    "KafkaController_OfflinePartitionsCount": $(cat /opt/app/conf/appctl/KafkaController_OfflinePartitionsCount.metrics)
#  }
#METRICS_EOF
# cat << METRICS_EOF
#  {
#    "heap_usage": $(parseMetrics "$metrics" ".jvm.memory.heap.usage" 100),
#    "MessagesInPerSec_1MinuteRate": $(parseMetricsForJmx "server" "BrokerTopicMetrics" "MessagesInPerSec" "OneMinuteRate" "MessagesInPerSec_1MinuteRate"),
#    "BytesInPerSec_1MinuteRate": $(parseMetricsForJmx "server" "BrokerTopicMetrics" "BytesInPerSec" "OneMinuteRate" "BytesInPerSec_1MinuteRate"),
#    "BytesOutPerSec_1MinuteRate": $(parseMetricsForJmx "server" "BrokerTopicMetrics" "BytesOutPerSec" "OneMinuteRate" "BytesOutPerSec_1MinuteRate"),
#    "Replica_MaxLag": $(parseMetricsForJmx "server" "ReplicaFetcherManager" "MaxLag,clientId=Replica" "Value" "Replica_MaxLag"),
#    "IsrExpandsPerSec_1MinuteRate": $(parseMetricsForJmx "server" "ReplicaManager" "IsrExpandsPerSec" "OneMinuteRate" "IsrExpandsPerSec_1MinuteRate"),
#    "KafkaController_ActiveControllerCount": $(parseMetricsForJmx "controller" "KafkaController" "ActiveControllerCount" "Value" "KafkaController_ActiveControllerCount"),
#    "KafkaController_OfflinePartitionsCount":$(parseMetricsForJmx "controller" "KafkaController" "OfflinePartitionsCount" "Value" "KafkaController_OfflinePartitionsCount")
#  }
#METRICS_EOF
}

parseMetrics() {
  local metrics="$1" key="$2" factor
  [ -z "$3" ] || factor="*$3"
  echo "$metrics" | xargs -n1 | awk -F: 'BEGIN{value=""} $1=="'$key'"{value=$2} END{print (value=="" ? 0 : value'$factor')}'
}

parseMetricsForJmxAll() {
  /opt/kafka/current/bin/kafka-run-class.sh kafka.tools.JmxTool --object-name kafka.server:type=BrokerTopicMetrics,name=MessagesInPerSec \
  --object-name kafka.server:type=BrokerTopicMetrics,name=BytesInPerSec \
  --object-name kafka.server:type=BrokerTopicMetrics,name=BytesOutPerSec \
  --object-name kafka.server:type=ReplicaFetcherManager,name=MaxLag,clientId=Replica \
  --object-name kafka.server:type=ReplicaManager,name=IsrExpandsPerSec \
  --object-name kafka.controller:type=KafkaController,name=ActiveControllerCount \
  --object-name kafka.controller:type=KafkaController,name=OfflinePartitionsCount \
  --report-format tsv --one-time true  > /opt/app/conf/appctl/kafka.metrics
}

parseMetricsForJmx() {
  /opt/kafka/current/bin/kafka-run-class.sh kafka.tools.JmxTool --object-name kafka.$1:type=$2,name=$3 --report-format tsv --one-time true |grep $4| awk '{printf("%.f",$2)}' > /opt/app/conf/appctl/$5.metrics
}

measure2() {
  JAVA_HOME=/opt/openjdk/current /opt/kafka/current/bin/kafka-jmx.sh \
  --object-name java.lang:type=Memory \
  --object-name kafka.server:type=BrokerTopicMetrics,name=MessagesInPerSec \
  --object-name kafka.server:type=BrokerTopicMetrics,name=BytesInPerSec \
  --object-name kafka.server:type=BrokerTopicMetrics,name=BytesOutPerSec \
  --object-name kafka.server:type=ReplicaFetcherManager,name=MaxLag,clientId=Replica \
  --object-name kafka.server:type=ReplicaManager,name=IsrExpandsPerSec \
  --object-name kafka.controller:type=KafkaController,name=ActiveControllerCount \
  --object-name kafka.controller:type=KafkaController,name=OfflinePartitionsCount \
  --report-format tsv --one-time 2>/dev/null > /opt/app/conf/appctl/kafka.metrics

  raw=$(awk '
/committed=[0-9]+, init=[0-9]+, max=[0-9]+, used=[0-9]+/ {
    match($0, /used=([0-9]+)/, used);
    match($0, /max=([0-9]+)/, max);
    if (max[1] > 0) {
        percentage = (used[1] / max[1]) * 100;
        printf("\"heap_usage\":%.f,\n", percentage);
    }
    next;
}
/kafka\.server:type=BrokerTopicMetrics,name=MessagesInPerSec:OneMinuteRate/ {
    split($0, fields, " ");
    printf("\"MessagesInPerSec_1MinuteRate\":%.f,\n", fields[length(fields)]);
    next;
}
/kafka\.server:type=BrokerTopicMetrics,name=BytesInPerSec:OneMinuteRate/ {
    split($0, fields, " ");
    printf("\"BytesInPerSec_1MinuteRate\":%.f,\n", fields[length(fields)]);
    next;
}
/kafka\.server:type=BrokerTopicMetrics,name=BytesOutPerSec:OneMinuteRate/ {
    split($0, fields, " ");
    printf("\"BytesOutPerSec_1MinuteRate\":%.f,\n", fields[length(fields)]);
    next;
}
/kafka\.server:type=ReplicaFetcherManager,name=MaxLag,clientId=Replica:Value/ {
    split($0, fields, " ");
    printf("\"Replica_MaxLag\":%d,\n", fields[length(fields)]);
    next;
}
/kafka\.server:type=ReplicaManager,name=IsrExpandsPerSec:OneMinuteRate/ {
    split($0, fields, " ");
    printf("\"IsrExpandsPerSec_1MinuteRate\":%.f,\n", fields[length(fields)]);
    next;
}
/kafka\.controller:type=KafkaController,name=ActiveControllerCount:Value/ {
    split($0, fields, " ");
    printf("\"KafkaController_ActiveControllerCount\":%d,\n", fields[length(fields)]);
    next;
}
/kafka\.controller:type=KafkaController,name=OfflinePartitionsCount:Value/ {
    split($0, fields, " ");
    printf("\"KafkaController_OfflinePartitionsCount\":%d,\n", fields[length(fields)]);
    next;
}
' /opt/app/conf/appctl/kafka.metrics)
  echo "{${raw::-1}}"
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
  tuning.kafkaManagedOffsetGroupExpireDays=7"
  if [ "$1" == "--update" ]; then
    params="operation=Update $params"
  fi
  if [ "${SASL}" == "SCRAM-SHA-512" ]; then
    local addParams="
    securityProtocol=SASL_PLAINTEXT
    saslMechanism=SCRAM-SHA-512
    jaasConfig=org.apache.kafka.common.security.scram.ScramLoginModule required username="${SASL_USER}" password="${SASL_PASSWD}";
    "
    params="$params $addParams"
  elif [ "${SASL}" == "SCRAM-SHA-256" ]; then
    local addParams="
    securityProtocol=SASL_PLAINTEXT
    saslMechanism=SCRAM-SHA-256
    jaasConfig=org.apache.kafka.common.security.scram.ScramLoginModule required username="${SASL_USER}" password="${SASL_PASSWD}";
    "
    params="$params $addParams"
  elif [ "${SASL}" == "SASL_PLAINTEXT" ]; then
    local addParams="
    securityProtocol=SASL_PLAINTEXT
    saslMechanism=SCRAM-SHA-256
    jaasConfig=org.apache.kafka.common.security.plain.PlainLoginModule required username="${SASL_USER}" password="${SASL_PASSWD}";
    "
    params="$params $addParams"
  else
    local addParams="
    securityProtocol=PLAINTEXT
     saslMechanism=DEFAULT
     jaasConfig=""
     "
    params="$params $addParams"
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

create_zk_node() {
  JAVA_HOME=/opt/openjdk/current /opt/kafka/current/bin/zookeeper-shell.sh ${ZK_NODES} create /kafka/${CLUSTER_ID}
}

check_zk_node() {
  JAVA_HOME=/opt/openjdk/current /opt/kafka/current/bin/zookeeper-shell.sh ${ZK_NODES} ls /kafka/${CLUSTER_ID}
}

retry_create_zk_node() {
  local tried=0
  local maxAttempts=5
  local interval=20
  local stopCode=0
  local retCode=0
  while [ $tried -lt $maxAttempts ]; do
     check_zk_node && {
      retCode=$?
      if [ "$retCode" = "$stopCode" ]; then
        log "Info: zk nodes /kafka/${CLUSTER_ID} exists"
        return $retCode
      fi
    }
    create_zk_node && {
      retCode=$?
      if [ "$retCode" = "$stopCode" ]; then
        log "Info: zk nodes /kafka/${CLUSTER_ID} create successfully"
      else
        sleep $interval
        tried=$((tried+1))
      fi
    }
  done

  log "Info: Create zk nodes /kafka/${CLUSTER_ID} still returned errors after $tried attempts. Stopping ..."
  return $retCode
}

upgrade() {
  log "INFO: wait for node health ok"
  retry 120 2 0 check
  sleep 10
  log "INFO: upgrade done!"
  log "WARN: be sure to rolling restart kafka again to set proper inter.broker.protocol.version and log.message.format.version"
}

# check inter.broker.protocol.version
# current IBPV is 3.8
# $1 count of 3.8
CURRENT_IBPV="3.8"
checkCurrentIBPV() {
  if [ "$1" -eq 0 ]; then
    log "INFO: first nodes, skip the check"
    return 0
  fi

  raw=$(JAVA_HOME=/opt/openjdk/current /opt/kafka/current/bin/kafka-configs.sh \
    --command-config /opt/app/conf/kafka/consumer.properties \
    --bootstrap-server $MY_IP:$MY_PORT --describe --entity-type brokers --all \
    | grep 'inter\.broker\.protocol\.version' | awk '{print $1}')
  cnt=$(echo "$raw" | grep -F "$CURRENT_IBPV" | wc -l)
  if [ "$cnt" -lt "$1" ]; then
    log "INFO: waiting for other nodes restarting: $cnt/$1"
    return 1
  fi
}

checkCurrentLMFV() {
  if [ "$1" -eq 0 ]; then
    log "INFO: first nodes, skip the check"
    return 0
  fi

  raw=$(JAVA_HOME=/opt/openjdk/current /opt/kafka/current/bin/kafka-configs.sh \
    --command-config /opt/app/conf/kafka/consumer.properties \
    --bootstrap-server $MY_IP:$MY_PORT --describe --entity-type brokers --all \
    | grep 'log\.message\.format\.version' | awk '{print $1}')
  cnt=$(echo "$raw" | grep -F "$CURRENT_LMFV" | wc -l)
  if [ "$cnt" -lt "$1" ]; then
    log "INFO: waiting for other nodes restarting: $cnt/$1"
    return 1
  fi
}

postUpgradeRestart() {
  rollingType=$(echo "$@" | grep -o '"rollingType":"[^"]*"' | sed 's/"rollingType":"//;s/"//')
  if [ -z "$rollingType" ]; then
    log "INFO: unknown rolling type, do noting"
    return 0
  fi
  
  idx=$(echo "$KAFKA_NODES" | nl | grep -F "$MY_IP" | awk '{print $1}')
  if [ "$rollingType" = "ibpv" ] && grep -q '^inter\.broker\.protocol\.version' $KAFKA_PROPERTIES_FILE; then
    log "INFO: remove inter.broker.protocol.version for restart"
    sed -i '/^inter\.broker\.protocol\.version/d' $KAFKA_PROPERTIES_FILE
    retry 3600 2 0 checkCurrentIBPV $((idx-1))
    log "INFO: restart kafka.service"
    systemctl restart kafka.service || :
    return 0
  fi

  if [ "$rollingType" = "lmfv" ] && grep -q '^log\.message\.format\.version' $KAFKA_PROPERTIES_FILE; then
    if grep -q '^inter\.broker\.protocol\.version' $KAFKA_PROPERTIES_FILE; then
      log "ERROR: inter.broker.protocol.version has value, please unset it first"
      return 1
    fi
    log "INFO: remove log.message.format.version for restart"
    sed -i '/^log\.message\.format\.version/d' $KAFKA_PROPERTIES_FILE
    retry 3600 2 0 checkCurrentLMFV $((idx-1))
    log "INFO: restart kafka.service"
    systemctl restart kafka.service || :
    return 0
  fi

  log "INFO: no condition met for rolling restart, do noting"
}