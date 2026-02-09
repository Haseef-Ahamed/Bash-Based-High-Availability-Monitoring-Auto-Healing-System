#!/bin/bash
#------------------------------------------
# Script header & globals
#------------------------------------------
                # CONF_FILE="./services.conf"
                # HEALTH_LOG="./service_health.log"
                # INCIDENT_LOG="./incidents.txt"

                # touch "$(dirname "$HEALTH_LOG")" "$(dirname "$INCIDENT_LOG")"
# Get absolute path of script directory
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

CONF_FILE="$BASE_DIR/services.conf"
HEALTH_LOG="$BASE_DIR/service_health.log"
INCIDENT_LOG="$BASE_DIR/incidents.txt"

# Force create log files
touch "$HEALTH_LOG" "$INCIDENT_LOG"

CHECK_INTERVAL=5
MAX_RETRIES=4
BASE_DELAY=2

declare -A SERVICE_UPTIME
declare -A SERVICE_DOWNTIME
START_TIME=$(date +%s)

#------------------------------------------
# Logging functions
#------------------------------------------
log_health() {
    echo "$(date '+%F %T') | $1" >> "$HEALTH_LOG"
}


log_incident() {
    echo "$(date '+%F %T') | $1" >> "$INCIDENT_LOG"
}

#------------------------------------------
# Service health check function
#------------------------------------------
log_health "Service Guardian started"
check_systemctl() {
    systemctl is-active --quiet "$1"
}

check_port() {
    ss -lnt | awk '{print $4}' | grep -q ":$1$"
}

check_response() {
    eval "$1" &>/dev/null
}

#------------------------------------------
#Smart restart (exponential backoff)
#------------------------------------------
restart_service() {
    local service=$1
    local retry=0

    while (( retry < MAX_RETRIES )); do
        systemctl restart "$service"
        sleep 2

        if check_systemctl "$service"; then
            log_health "$service restarted successfully"
            return 0
        fi

        delay=$(( BASE_DELAY * (2 ** retry) ))
        log_incident "$service restart failed, retry $((retry+1)) in ${delay}s"
        sleep "$delay"
        ((retry++))
    done

    log_incident "$service FAILED after $MAX_RETRIES retries"
    return 1
}

#------------------------------------------
# Dependency check function
#------------------------------------------
handle_dependencies() {
    local deps=$1
    IFS=',' read -ra DEP_ARRAY <<< "$deps"

    for dep in "${DEP_ARRAY[@]}"; do
        [[ -z "$dep" ]] && continue
        if ! check_systemctl "$dep"; then
            restart_service "$dep"
        fi
    done
}

#------------------------------------------
# Log watcher (real-time error detection)
#------------------------------------------
monitor_logs() {
    local service=$1
    local logfile=$2

    tail -Fn0 "$logfile" | while read line; do
        if echo "$line" | grep -Ei "error|fail|panic|critical"; then
            log_incident "$service log error: $line"
        fi
    done &
}

#------------------------------------------
# Uptime & availability tracking
#------------------------------------------
update_uptime() {
    local service=$1
    local status=$2

    if [[ "$status" == "up" ]]; then
        ((SERVICE_UPTIME[$service]+=CHECK_INTERVAL))
    else
        ((SERVICE_DOWNTIME[$service]+=CHECK_INTERVAL))
    fi
}

#------------------------------------------
# Main monitoring logic (per service)
#------------------------------------------
monitor_service() {
    if [[ "$ENABLED" != "yes" ]]; then
        return
    fi

    if check_systemctl "$SERVICE_NAME" &&
       check_port "$PORT" &&
       check_response "$CHECK_CMD"; then

        log_health "$SERVICE_NAME healthy"
        update_uptime "$SERVICE_NAME" "up"
    else
        log_incident "$SERVICE_NAME unhealthy"
        update_uptime "$SERVICE_NAME" "down"

        handle_dependencies "$DEPENDS_ON"
        restart_service "$SERVICE_NAME"
    fi
}

#------------------------------------------
# Parse services.conf and loop forever (daemon mode)
#------------------------------------------
run_guardian() {
    while true; do
        current_block=""

        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue

            if [[ "$line" == "---" ]]; then
                source <(echo "$current_block")
                monitor_service
                unset SERVICE_NAME ENABLED PORT CHECK_CMD DEPENDS_ON LOG_FILE
                current_block=""
            else
                current_block+="$line"$'\n'
            fi
        done < "$CONF_FILE"

        sleep "$CHECK_INTERVAL"
    done
}

