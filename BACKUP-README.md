# Rocket.Chat MongoDB Backup System

## Overview

Automated weekly backup system for Rocket.Chat MongoDB database, configured according to the [official Rocket.Chat documentation](https://docs.rocket.chat/v1/docs/deploy-with-docker-docker-compose).

## Backup Schedule

- **Frequency**: Weekly
- **Day**: Every Sunday
- **Time**: 2:00 AM
- **Retention**: 28 days (4 weeks)

## Backup Location

```
/opt/stacks/rocketchat/backups/
```

## Files

- **Backup Script**: `/opt/stacks/rocketchat/backup-mongodb.sh`
- **Backup Files**: `/opt/stacks/rocketchat/backups/rocketchat-backup-YYYY-MM-DD_HH-MM-SS.archive`
- **Log File**: `/opt/stacks/rocketchat/backups/backup.log`

## Manual Backup

To create a manual backup at any time:

```bash
/opt/stacks/rocketchat/backup-mongodb.sh
```

## Restore from Backup

To restore from a backup file:

```bash
# Navigate to the rocketchat directory
cd /opt/stacks/rocketchat

# Restore from backup archive
docker compose exec -T mongodb mongorestore --archive < backups/rocketchat-backup-YYYY-MM-DD_HH-MM-SS.archive
```

## Cron Configuration

The backup is scheduled via cron:

```cron
0 2 * * 0 /opt/stacks/rocketchat/backup-mongodb.sh >> /opt/stacks/rocketchat/backups/backup.log 2>&1
```

To view or edit the cron job:

```bash
crontab -l  # View current cron jobs
crontab -e  # Edit cron jobs
```

## Monitoring

Check the backup log to verify successful execution:

```bash
tail -50 /opt/stacks/rocketchat/backups/backup.log
```

Check backup files and disk usage:

```bash
ls -lh /opt/stacks/rocketchat/backups/
du -sh /opt/stacks/rocketchat/backups/
```

## Backup Features

1. **Automatic Cleanup**: Backups older than 28 days are automatically deleted
2. **Detailed Logging**: All backup operations are logged with timestamps
3. **Error Handling**: Script exits with error codes and logs failures
4. **Size Reporting**: Each backup's size is recorded in the log

## Current Backup Status

- MongoDB Version: 8.2.1
- Database: rocketchat
- First backup created: 2025-10-15
- Test backup size: ~403 MB

## Troubleshooting

### Check if containers are running
```bash
docker compose ps
```

### Test backup script manually
```bash
/opt/stacks/rocketchat/backup-mongodb.sh
```

### View MongoDB container logs
```bash
docker compose logs mongodb
```

### Check disk space
```bash
df -h /opt/stacks/rocketchat/backups/
```

## Important Notes

- Ensure sufficient disk space for backups (estimate ~400-500 MB per backup)
- With 4 weeks retention, expect ~2 GB total storage for backups
- Backups are stored on the host system, not inside containers
- The script automatically removes backups from the container after copying to host
