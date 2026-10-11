#!/bin/bash
#
# Rocket.Chat MongoDB Backup Script
# Based on: https://docs.rocket.chat/v1/docs/deploy-with-docker-docker-compose
#
# This script creates a backup of the MongoDB database used by Rocket.Chat
# and retains the last 4 weekly backups (1 month)
#

# Configuration
BACKUP_DIR="/opt/stacks/rocketchat/backups"
COMPOSE_DIR="/opt/stacks/rocketchat"
BACKUP_NAME="rocketchat-backup-$(date +%Y-%m-%d_%H-%M-%S).archive"
LOG_FILE="$BACKUP_DIR/backup.log"
RETENTION_DAYS=28  # Keep 4 weeks of backups

# Function to log messages
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Start backup
log "Starting MongoDB backup..."

# Change to compose directory
cd "$COMPOSE_DIR" || {
    log "ERROR: Could not change to directory $COMPOSE_DIR"
    exit 1
}

# Create backup using mongodump via docker compose (output directly to host)
if docker compose exec -T mongodb mongodump --archive --db=rocketchat > "$BACKUP_DIR/$BACKUP_NAME"; then
    log "SUCCESS: Backup created: $BACKUP_DIR/$BACKUP_NAME"

    # Get backup size
    BACKUP_SIZE=$(du -h "$BACKUP_DIR/$BACKUP_NAME" | cut -f1)
    log "Backup size: $BACKUP_SIZE"
else
    log "ERROR: Backup failed"
    exit 1
fi

# Clean up old backups (keep last 28 days)
log "Cleaning up backups older than $RETENTION_DAYS days..."
find "$BACKUP_DIR" -name "rocketchat-backup-*.archive" -type f -mtime +$RETENTION_DAYS -delete
REMAINING=$(find "$BACKUP_DIR" -name "rocketchat-backup-*.archive" -type f | wc -l)
log "Retained $REMAINING backup(s)"

# Display disk usage
TOTAL_SIZE=$(du -sh "$BACKUP_DIR" | cut -f1)
log "Total backup directory size: $TOTAL_SIZE"

log "Backup completed successfully"
exit 0
