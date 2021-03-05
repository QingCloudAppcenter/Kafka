#!/usr/bin/env bash

#ln -s /opt/app/bin/node/kfkctl.sh  /usr/bin/kfkctl

# apply base env file
for envFile in $(find /opt/app/bin/envs -name "*.env"); do . $envFile; done

retry() {
  local tried=0
  local maxAttempts=$1
  local interval=$2
  local stopCode=$3
  local cmd="${@:4}"
  local retCode=0
  while [ $tried -lt $maxAttempts ]; do
    $cmd && return 0 || {
      retCode=$?
      if [ "$retCode" = "$stopCode" ]; then
        echo "'$cmd' returned with stop code $stopCode. Stopping ..." && return $retCode
      fi
    }
    sleep $interval
    tried=$((tried+1))
  done

  echo "'$cmd' still returned errors after $tried attempts. Stopping ..." && return $retCode
}

checkRole() {
  if [[ "$1" = "ALL" ]] || [[ "$1" = "${MY_ROLE}" ]]; then
    return 0
  else
    echo "wrong role! this function required role : "$1;
    return 1
  fi
}


#func0
# 列出所有的topic
listAllTopic() {
  /opt/kafka/current/bin/kafka-topics.sh --list --zookeeper ${zookeeperList}
}


#func1
# 新建topic
createTopic() {
  local topicName  replicationFactor partitionsNum
  echo "please input as required: (Use spaces to differentiate )"
  read -p "topic name:  num of replication:   num of partitions:  "  topicName  replicationFactor partitionsNum

/opt/kafka/current/bin/kafka-topics.sh    --create \
                                          --zookeeper ${zookeeperList} \
                                          --replication-factor ${replicationFactor:-1} \
                                          --partitions ${partitionsNum:-3} \
                                          --topic ${topicName:-test}
}


#func2
# 删除topic
deleteTopic() {
  local topicName
  read -p "please input the topic name which you want to delete: "     topicName 
  /opt/kafka/current/bin/kafka-topics.sh  --delete \
                                          --zookeeper ${zookeeperList} \
                                          --topic ${topicName}
}



#func3
# 获取topic的详细信息
describeTopic() {
  local topicName
  echo "note : all topic are displayed by default, but it will only output the specified topic if you input the topic name ";
  read -p "please input the target topic name: " topicName
  /opt/kafka/current/bin/kafka-topics.sh  --zookeeper ${zookeeperList} --describe  `if [[ $topicName ]]; then echo --topic ${topicName}; fi`
}


#func4
# 启动console producer
consoleProducer() {
  local topicName
  read -p "please input the target topic name: " topicName
  /opt/kafka/current/bin/kafka-console-producer.sh --broker-list ${brokerList} --topic ${topicName}
}

#func5
# 启动console consumer
consoleConsumer() {
  local isConsumeFromBeginning consumerGroup maxMeassagesNum offsetsNum partitionsNum topicName
  echo "please input as required: "
  read -p "--from-beginning(1:true, 0:false)  "   isConsumeFromBeginning
  read -p "--group <consumer group id>   "        consumerGroup
  read -p "--max-messages  "                      maxMeassagesNum
  read -p "--offset <consume offset>  "           offsetsNum
  read -p "--partition  "                         partitionsNum
  read -p "--topic "                              topicName
  /opt/kafka/current/bin/kafka-console-consumer.sh --bootstrap-server ${brokerList} \
                        `if [[ "${isConsumeFromBeginning}" = "1" ]]; then echo --from-beginning; fi` \
                        `if [[ $consumerGroup ]]; then echo --group ${consumerGroup}; fi` \
                        `if [[ $maxMeassagesNum ]]; then echo --max-messages ${maxMeassagesNum}; fi` \
                        `if [[ $offset ]]; then echo --offset ${offsetsNum}; fi` \
                        `if [[ $partitionsNum ]]; then echo --partition ${partitionsNum}; fi` \
                        `if [[ $topicName ]]; then echo --topic ${topicName}; fi`
}



#func6
# 平衡分区
performPreferredReplicaElection() {
  /opt/kafka/current/bin/kafka-preferred-replica-election.sh --zookeeper ${zookeeperList}
}


#func7
# consumer group tool
consumerGroupManager() {
  local actionNum
  echo "Command must include exactly one action: ";
  echo "1--list, 2--describe, 3--delete, 4--reset-offsets";
  read -p "choose your action: " actionNum
  case ${actionNum} in
  1) listAllConsumerGroup ;;
  2) describeConsumergroup ;;
  3) deleteConsumerGroupInfo ;;
  4) resetOffset ;;
  *) echo "wrong input!" ;;
  esac
}

listAllConsumerGroup() {
  /opt/kafka/current/bin/kafka-consumer-groups.sh --bootstrap-server ${brokerList} --list
}

describeConsumergroup() {
  local consumerGroup
  read -p "input the group you want to describe: " consumerGroup
  /opt/kafka/current/bin/kafka-consumer-groups.sh --bootstrap-server ${brokerList} --describe --group ${consumerGroup}
  /opt/kafka/current/bin/kafka-consumer-groups.sh --bootstrap-server ${brokerList} --describe --group ${consumerGroup} --state 
}

deleteConsumerGroupInfo() {
  #Pass in groups to delete topic partition offsets and ownership information over the entire consumer group.
  local consumerGroup confirmFlag
  read -p "input the group you want to delete: " consumerGroup
  echo "please confirm the group you want to delete is " ${consumerGroup} 
  read -p "current mode : dry run ; executing only when you input yes : " confirmFlag
  /opt/kafka/current/bin/kafka-consumer-groups.sh --bootstrap-server ${brokerList} --delete --group ${consumerGroup}  `if [[ "${confirmFlag}" == "yes" ]]; then echo --execute; else echo --dry-run; fi`
}

resetOffset() {
  local topicName consumerGroup isReset2Earlist isReset2Latest offsetsNum offsetsDate confirmFlag
  echo "please input as required: "
  read -p "--topic  "                                           topicName
  read -p "--group  "                                           consumerGroup
  read -p "--to-earliest(1:true, 0:false)  "                    isReset2Earlist
  read -p "--to-latest(1:true, 0:false)   "                     isReset2Latest
  read -p "--to-offset(int)  "                                  offsetsNum
  read -p "--to-datetime(Format: 'YYYY-MM-DDTHH:mm:SS.sss')  "  offsetsDate
  read -p "current mode : dry run ; executing only when you input yes : " confirmFlag
  
  /opt/kafka/current/bin/kafka-consumer-groups.sh --reset-offsets \
                                                  --bootstrap-server ${brokerList} \
                                                  `if [[ "${confirmFlag}" == "yes" ]]; then echo --execute; else echo --dry-run; fi` \
                                                  `if [[ ${consumerGroup} ]]; then echo --group ${consumerGroup}; fi` \
                                                  `if [[ "${isReset2Earlist}" = "1" ]]; then echo --to-earliest; fi` \
                                                  `if [[ "${isReset2Latest}" = "1" ]]; then echo --to-latest; fi` \
                                                  `if [[ $topicName ]]; then echo --topic ${topicName}; fi` \
                                                  `if [[ ${consumerGroup} ]]; then echo --to-offset ${offsetsNum}; fi` \
                                                  `if [[ ${offsetsDate} ]]; then echo --to-datatime ${offsetsDate}; fi`
}

#func8
# description

func8() {
  echo "not avaliable now.";
}




#func9
# description

func9() {
  echo "not avaliable now.";
}



switch2func() {
  case ${1} in
  0) checkRole ALL && listAllTopic ;;
  1) checkRole ALL && createTopic ;;
  2) checkRole ALL && deleteTopic ;;
  3) checkRole ALL && describeTopic ;;
  4) checkRole ALL && consoleProducer ;;
  5) checkRole ALL && consoleConsumer ;;
  6) checkRole ALL && performPreferredReplicaElection ;;
  7) checkRole ALL && consumerGroupManager ;;
  8) checkRole kafka && func8 ;;   #ALL means this func should be works well in all node
  9) checkRole kafka-manager && func9 ;;
  *) echo "wrong input! please retry" ;;
  esac
}

displayMenu() {
  echo "************************ kafka ctl menu ************************";
  echo "    0    list all topic             1    create new topic       ";
  echo "    2    delete topic               3    get topic's detail     ";
  echo "    4    console producer           5    console consumer       ";
  echo "    6    rebalance replica          7    consumer group manager ";
  echo "    8    not avaliable now          9    not avaliable now      ";
  echo "    m/M  redisplay menu             q/Q  exit                   ";
  echo "****************************************************************";
}

main() {
  displayMenu
  local commandNum
  while true; do
    read -p "please input function code --> " commandNum;
    case ${commandNum} in
    [0-9]) switch2func ${commandNum} ;;
    m*|M*) displayMenu ;;
    q*|Q*) echo "exit kfkctl. thanks for use."; break ;;
    *) echo "wrong input! please retry" ;;
    esac
  done
}


zks=""
for i in $(curl -s  metadata/self/links/zk_service/hosts | grep /ip | awk '{print $2}'); do zks=$zks$i:2181,; done
zookeeperList=${zks%,*}/kafka/`curl -s metadata/self/cluster/cluster_id`

bs=""
for i in $(curl -s  metadata/self/hosts/kafka | grep /ip | awk '{print $2}'); do bs=$bs$i:9092,; done
#for i in $(grep 'href="//' /opt/app/conf/caddy/index.html | awk -F/ '{print $4}'); do bs=$bs$i:9092,; done  # may not avaliable in client node
brokerList=${bs%,*}




main