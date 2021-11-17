#!/bin/bash
##############################################################
#               INFO
# Put script in crontab with execution every 5 min
# example: */5 * * * * /bin/bash <scriptname> > /dev/null 2>&1
##############################################################

#############
# CONSTANTS
#############
# bash strict mode http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -euo pipefail

MAIL_RECIPIENTS=
PROXY_SERVER=
CPU_USAGE_PERCENTAGE_LIMIT=80
MEMORY_USAGE_PERCENTAGE_LIMIT=80
DISK_USAGE_PERCENTAGE_LIMIT=80
WEBHOOK=
# When execution in crontab is every 5 min
HEARTBEAT_COUNTER_LIMIT=2016 # once a week



MPSTAT=$(which mpstat)
MPSTAT=$?
if [ $MPSTAT != 0 ]
then
	echo "Please install mpstat!"	
	echo "On SUSE based systems:"
	echo "zypper install sysstat"
fi

BC=$(which bc)
BC=$?
if [ $BC != 0 ]
then
	echo "Please install mpstat!"	
	echo "On SUSE based systems:"
	echo "zypper install bc"
fi
#############
# FUNCTIONS
#############

# Formats a string so it can be sent to Mattermost.
# Mattermost requires \, \n, \t to be escaped so they are properly rendered.
#
# accepts: string
# returns: formatted string
function formatForMattermost () {

  local func_result
  func_result=$(echo "$1" | tr '\n' '@' | sed 's/@/\\n/g;' )
  echo "${func_result}"
}
# Check LoadAverage Status
function loadAverage () {
  
  local MAX_LOAD_AVERAGE=$1
  local LOAD_AVERAGE=$2
  local RETURN_CODE=0
  
  # floating-point compare in Bash
  if [[ $(echo "$LOAD_AVERAGE > $MAX_LOAD_AVERAGE" | bc -l) == 1 ]]; then
    echo "Unhealthy: LA > $MAX_LOAD_AVERAGE"
    RETURN_CODE=1 
  else
    echo "Normal: LA < $MAX_LOAD_AVERAGE"
  fi
  return $RETURN_CODE
}

# Print memory status and send alert if memory usage limit is exceeded
function memoryStat () {

  GB="$(printf 'GB\t')"  
  TOTALMEM=$(free -m | head -2 | tail -1| awk '{print $2}')
  TOTALBC=$(echo "scale=2;if($TOTALMEM<1024 && $TOTALMEM > 0) print 0;$TOTALMEM/1024"| bc -l)
  USEDMEM=$(free -m | head -2 | tail -1| awk '{print $3}')
  USEDBC=$(echo "scale=2;if($USEDMEM<1024 && $USEDMEM > 0) print 0;$USEDMEM/1024"|bc -l)
  FREEMEM=$(free -m | head -2 | tail -1| awk '{print $4}')
  FREEBC=$(echo "scale=2;if($FREEMEM<1024 && $FREEMEM > 0) print 0;$FREEMEM/1024"|bc -l)
  USAGE_PERCENTAGE=$((USEDMEM * 100 / TOTALMEM  ))
  
  OUTPUT=$(echo -e "
  Total $GB Used $GB Free $GB %USED

  ${TOTALBC} $GB ${USEDBC} $GB ${FREEBC} $GB $((USEDMEM * 100 / TOTALMEM  ))%
  ")


  if [[ "$USAGE_PERCENTAGE" -ge $MEMORY_USAGE_PERCENTAGE_LIMIT ]]; then
    alertMessage "Memory" "$USAGE_PERCENTAGE" $MEMORY_USAGE_PERCENTAGE_LIMIT  "${OUTPUT}"
  fi

  # Print weekly summary 
  echo "$OUTPUT"

}

# Print CPU usage and Load Average and send alert if limit is exeeded
function cpuStat () {

  
  # Ranges for CPU load average. nproc print the number of processing(CPU) units available.On a single core system this would mean:
  # load average: 1.00, 0.40, 3.35
  # The CPU was fully (100%) utilized on average; 1 processes was running on the CPU (1.00) over the last 1 minute.
  # The CPU was idle by 60% on average; no processes were waiting for CPU time (0.40) over the last 5 minutes.
  # The CPU was overloaded by 235% on average; 2.35 processes were waiting for CPU time (3.35) over the last 15 minutes.
  
  LOAD_AVERAGE_UNHEALTHY=$(nproc)
  # Use average usage for last 10s
  CPU_USAGE=$(mpstat 1 10 | tail -1 | awk '{printf("%d", 100 - $12) }')
  # load average  over the last 15 minutes.
  LOAD_AVERAGE=$(uptime | awk -F'load average:' '{ print $2 }' | cut -f3 -d,)
  
  # Print weekly summanry
  echo -e "
  CPU Usage : $CPU_USAGE %
  Load Average : $LOAD_AVERAGE
  Heath Status : $(loadAverage "$LOAD_AVERAGE_UNHEALTHY" "$LOAD_AVERAGE")      
  "
  OUTPUT_CPU="CPU Usage : $CPU_USAGE"
  # floating-point compare in Bash
  if [[ $(echo "$CPU_USAGE > $CPU_USAGE_PERCENTAGE_LIMIT" | bc -l) == 1 ]]; then
    alertMessage "CPU usage" "$CPU_USAGE" $CPU_USAGE_PERCENTAGE_LIMIT  "${OUTPUT_CPU}"
    alertMail "CPU usage" "$CPU_USAGE" $CPU_USAGE_PERCENTAGE_LIMIT  "${OUTPUT_CPU}"
  fi  

  OUTPUT_LOAD_AVERAGE="Load Average is too high : $LOAD_AVERAGE"  
  if [[ $(loadAverage "$LOAD_AVERAGE_UNHEALTHY" "$LOAD_AVERAGE") == 1 ]]; then 
    alertMessage "CPU Load Average" "$LOAD_AVERAGE" "$LOAD_AVERAGE_UNHEALTHY" "${OUTPUT_LOAD_AVERAGE}" 
    alertMail "CPU Load Average" "$LOAD_AVERAGE" "$LOAD_AVERAGE_UNHEALTHY" "${OUTPUT_LOAD_AVERAGE}"
  
  fi

}


# Print Disk usage and send alert if limit is exeeded on any partition
function diskStat () {

  local DF=$1
  # Check used space
  while read -r output;
  do
    USAGE_PERCENTAGE=$(echo "$output" | awk '{ print $5 }' | cut -d'%' -f1  )
    if [ "$USAGE_PERCENTAGE" -gt $DISK_USAGE_PERCENTAGE_LIMIT ]; then
      alertMessage "Disk" "$USAGE_PERCENTAGE" $DISK_USAGE_PERCENTAGE_LIMIT "$output"
      alertMail "Disk" "$USAGE_PERCENTAGE" $DISK_USAGE_PERCENTAGE_LIMIT "$output"
    fi  
  done <<<"$DF"
}

# Send alert to Mattermost
function alertMessage () {

  local ALERT_NAME=$1
  local USAGE_PERCENTAGE=$2
  local PERCENTAGE_LIMIT=$3
  local OUTPUT=$4  
  OUTPUT_FORMATTED=$(formatForMattermost "${OUTPUT}")
  cat << EOF > /tmp/report_alert_mattermost
  {"type": "mrkdwn",
   "text":"VM Alert PROD ${ALERT_NAME} usage percentage on $(hostname) is ${USAGE_PERCENTAGE}%. Limit is: ${PERCENTAGE_LIMIT}%",
   "attachments": [
        {
            "color": "#ff0000",
            "text": "Details: '${OUTPUT_FORMATTED}'."
        }
    ]
    }
EOF
  curl -x $PROXY_SERVER -k -X POST -H 'Content-type: application/json' --data @/tmp/report_alert_mattermost $WEBHOOK
  rm /tmp/report_alert_mattermost

}

# Send Alert via Mail
function alertMail () {

  local ALERT_NAME=$1
  local USAGE_PERCENTAGE=$2
  local USAGE_PERCENTAGE_LIMIT=$3
  local OUTPUT=$4

  SENDER=vm.alert@nra.bg
  SUBJECT="Subject: VM Alert PROD ${ALERT_NAME} usage percentage on $(hostname) is ${USAGE_PERCENTAGE}%. Limit is: ${USAGE_PERCENTAGE_LIMIT}%"

  tee /tmp/report_alert_mail >/dev/null <<EOF
${SUBJECT}

Alert script execution report:

Details: '${OUTPUT}'%.
EOF

  /usr/sbin/sendmail -F $SENDER $MAIL_RECIPIENTS < /tmp/report_alert_mail

  # Remove message file
  rm /tmp/report_alert_mail

}

# Send heartbeat mail once a week reportng the condition on the server (node) 
function weeklyMail () {

  DISK_STATUS=$1
  UPTIME_STATUS=$2
  MEMORY_STATUS=$3
  CPU_STATUS=$4

  SENDER=vm.status@nra.bg
  SUBJECT="Subject: VM Status PROD Weekly running on $(hostname):"  
  tee /tmp/system_status_mail >/dev/null <<EOF
${SUBJECT}

- Disk status:
 ${DISK_STATUS}

- Uptime : 
${UPTIME_STATUS}

- Memory status: 
${MEMORY_STATUS}

- CPU status:
 ${CPU_STATUS}

EOF

  /usr/sbin/sendmail -F $SENDER $MAIL_RECIPIENTS < /tmp/system_status_mail  
  # Remove message file
  rm /tmp/system_status_mail
}

# Send heartbeat Mattermost message once a week reportng the condition on the server (node) 
function weeklyStat () {

  DISK_STATUS=$1
  UPTIME_STATUS=$2
  MEMORY_STATUS=$3
  CPU_STATUS=$4
  
  DISK_STATUS_FORMATTED=$(formatForMattermost "${DISK_STATUS}")
  MEMORY_FORMATTER=$(formatForMattermost "$MEMORY_STATUS")
  CPU_FORMATTER=$(formatForMattermost "$CPU_STATUS")
  cat << EOF > /tmp/system_status_mattermost
{"type": "mrkdwn",
 "text":"SYSTEM STATUS check running on  $(hostname) :+1:",
  "attachments": [
       {
         "color": "#00E500",
         "text": "$UPTIME_STATUS"
       },
       {
         "color": "#00E500",
         "text": "$DISK_STATUS_FORMATTED"
       },
       {
         "color": "#00E500",
         "text": "$MEMORY_FORMATTER"
       },
       {
         "color": "#00E500",
         "text": "$CPU_FORMATTER"
       }
 ]
}
EOF

  # periodically get a notification to be sure the heartbeat works
  curl -x $PROXY_SERVER -k -X POST -H 'Content-type: application/json' --data @/tmp/system_status_mattermost $WEBHOOK  
  rm /tmp/system_status_mattermost
  # reset counter in file to 0
  echo 0 > "$COUNTER_PATH"

}


########
# MAIN
########


# Show Uptime and last reboot
UPTIME_NOW=$(echo -e "Uptime: $(uptime | sed 's/.*up \([^,]*\), .*/\1/'), Last Reboot: $(who -b | awk '{print $3,$4}')")

# Show information about the file system on which each FILE resides,
# or all file systems by default.
DF=$(df -P | grep -vE '^Filesystem|tmpfs' | grep -v /boot/)

# Call usage functions
diskStat "$DF"
cpuStat
memoryStat

### Send heartbeat

COUNTER_PATH="/tmp/counter"

#check counter file exist, otherwise create new one with value 0
if [[ -e $COUNTER_PATH ]]; then
   COUNTER_PATH="/tmp/counter"
else
   echo 0 > /tmp/counter
fi


# load counter value, increment and update in file
counter=$(cat ${COUNTER_PATH})
counter=$((counter + 1))
echo $counter > $COUNTER_PATH

if [ "$counter" -eq "$HEARTBEAT_COUNTER_LIMIT" ];then
  weeklyMail "$DF" "$UPTIME_NOW" "$(memoryStat)" "$(cpuStat)"
  weeklyStat "$DF" "$UPTIME_NOW" "$(memoryStat)" "$(cpuStat)"
fi
