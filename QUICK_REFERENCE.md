# Quick Reference Guide

## Start Monitoring
```bash
sudo ./service_guardian.sh
```

## Stop Monitoring
Press `Ctrl+C` for graceful shutdown with availability report

## Configuration File
Edit `services.conf` to add/modify services

## Log Files
- `service_health.log` - All health checks and reports
- `incidents.txt` - Failures and restart attempts

## Key Settings (in service_guardian.sh)
```bash
CHECK_INTERVAL=5    # Check every 5 seconds
MAX_RETRIES=4       # 4 restart attempts
BASE_DELAY=2        # Exponential backoff base
```

## Test Service Failure
```bash
# Stop a service to test auto-restart
sudo systemctl stop mysql

# Watch the logs
tail -f incidents.txt
```

## View Current Status
```bash
# Check health log
tail -20 service_health.log

# Check incidents
tail -20 incidents.txt
```

## Add New Service
Edit `services.conf`:
```bash
SERVICE_NAME=your-service
ENABLED=yes
PORT=1234
CHECK_CMD="your-health-check"
DEPENDS_ON=dependency1,dependency2
LOG_FILE=/var/log/your-service/error.log
---
```
