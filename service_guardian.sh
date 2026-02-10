#!/bin/bash
#------------------------------------------
# Service Guardian - High Availability Monitoring System
# Monitors: Nginx, MySQL, Redis
#------------------------------------------

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
# Service health check functions
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
# Smart restart (exponential backoff)
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

    tail -Fn0 "$logfile" 2>/dev/null | while read line; do
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

    if check_systemctl "$SERVICE_NAME" && \
       check_port "$PORT" && \
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

#------------------------------------------
# Start log monitoring for all services
#------------------------------------------
start_log_monitors() {
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue

        if [[ "$line" =~ ^SERVICE_NAME=(.+)$ ]]; then
            current_service="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^LOG_FILE=(.+)$ ]]; then
            current_logfile="${BASH_REMATCH[1]}"
            if [[ -n "$current_service" && -n "$current_logfile" && -f "$current_logfile" ]]; then
                monitor_logs "$current_service" "$current_logfile"
                log_health "Started log monitor for $current_service ($current_logfile)"
            fi
        fi
    done < "$CONF_FILE"
}

#------------------------------------------
# Calculate and display availability stats
#------------------------------------------
show_availability() {
    local total_runtime=$(($(date +%s) - START_TIME))
    
    echo ""
    echo "========================================="
    echo "  SERVICE AVAILABILITY REPORT"
    echo "========================================="
    echo "Total Runtime: $((total_runtime / 60)) minutes"
    echo ""
    
    for service in "${!SERVICE_UPTIME[@]}"; do
        local uptime=${SERVICE_UPTIME[$service]:-0}
        local downtime=${SERVICE_DOWNTIME[$service]:-0}
        local total=$((uptime + downtime))
        
        if (( total > 0 )); then
            local availability=$(awk "BEGIN {printf \"%.2f\", ($uptime / $total) * 100}")
            echo "[$service]"
            echo "  Uptime: ${uptime}s | Downtime: ${downtime}s"
            echo "  Availability: ${availability}%"
            echo ""
        fi
    done
    
    log_health "Availability report generated"
}

#------------------------------------------
# Graceful shutdown handler
#------------------------------------------
cleanup() {
    echo ""
    log_health "Service Guardian shutting down..."
    show_availability
    
    # Kill all background log monitoring processes
    jobs -p | xargs -r kill 2>/dev/null
    
    log_health "Service Guardian stopped"
    exit 0
}

#------------------------------------------
# Periodic availability reporting (background)
#------------------------------------------
periodic_report() {
    while true; do
        sleep 300  # Report every 5 minutes
        show_availability >> "$HEALTH_LOG"
    done
}

#------------------------------------------
# Main execution
#------------------------------------------
trap cleanup SIGINT SIGTERM

echo "========================================="
echo "  SERVICE GUARDIAN STARTED"
echo "========================================="
echo "Monitoring: Nginx, MySQL, Redis"
echo "Check Interval: ${CHECK_INTERVAL}s"
echo "Logs: $HEALTH_LOG | $INCIDENT_LOG"
echo "========================================="
echo ""

# Initialize uptime counters for all services
while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^SERVICE_NAME=(.+)$ ]]; then
        service_name="${BASH_REMATCH[1]}"
        SERVICE_UPTIME[$service_name]=0
        SERVICE_DOWNTIME[$service_name]=0
    fi
done < "$CONF_FILE"

# Start log monitors for all services
start_log_monitors

# Start periodic availability reporting in background
periodic_report &

# Run the main guardian loop
run_guardian
