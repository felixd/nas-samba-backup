#!/bin/bash
# Author: Paweł 'felixd' Wojciechowski
# (c) 2025 - FlameIT - Immersion Cooling

# Cleanup function will be called automatically on script exit
# If you want to run this script periodically, consider using cron jobs or systemd timers.
# Make sure to test the script in a safe environment before deploying it in production.
# Good luck with your backups! :)
# Note: This script assumes that the user running it has sudo privileges to mount and unmount shares.
# Note: Weekly backups older than 30 days are removed.

# Default .env settings
# NAS_IP="127.0.0.1"   # NAS IP address
# NAS Mount point
# SOURCE_DIR="/mnt/source"
# Backup directory
# BACKUP_DIR="/mnt/backup"
# BACKUP_DIR_WEEKLY="/mnt/backup-weekly"
# NAS_USER="backup"
# NAS_PASSWORD=""

# set -euo pipefail
SMBVERSION="3.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source_env() {
    echo "Configuration loading"
    env="${SCRIPT_DIR}/.env"
    [ ! -f "${env}" ] && {
        echo "Env file ${env} doesn't exist. Make sure you have created it and filled it with correct values."
        echo "Example .env file:"
        echo "NAS_IP=127.0.0.1"
        echo "SOURCE_DIR=/mnt/source"
        echo "BACKUP_DIR=/mnt/backup"
        echo "BACKUP_DIR_WEEKLY=/mnt/backup-weekly"
        echo "NAS_USER=backup"
        echo "NAS_PASSWORD=your_password"
        echo "SMBVERSION=3.0"
        echo "Exiting"
        return 1
    }
    eval $(sed -e '/^\s*$/d' -e '/^\s*#/d' -e 's/=/="/' -e 's/$/"/' -e 's/^/export /' "${env}")
}

# Loading .env file
source_env

# Check if required variables are set
if [ -z "$NAS_IP" ] || [ -z "$SOURCE_DIR" ] || [ -z "$BACKUP_DIR" ] || [ -z "$NAS_USER" ] || [ -z "$NAS_PASSWORD" ]; then
    echo "One or more required variables are not set in the .env file."
    echo "Please ensure NAS_IP, SOURCE_DIR, BACKUP_DIR, NAS_USER, and NAS_PASSWORD are set."
    exit 1
fi
# Check if the source directory is an absolute path
if [[ "$SOURCE_DIR" != /* ]]; then
    echo "SOURCE_DIR must be an absolute path. Please update your .env file."
    exit 1
fi
# Check if the backup directory is an absolute path
if [[ "$BACKUP_DIR" != /* ]]; then
    echo "BACKUP_DIR must be an absolute path. Please update your .env file."
    exit 1
fi
# Check if the backup directory is an absolute path
if [[ "$BACKUP_DIR_WEEKLY" != /* ]]; then
    echo "BACKUP_DIR_WEEKLY must be an absolute path. Please update your .env file."
    exit 1
fi

# If BACKUP_DIR ends with a slash, remove it
if [[ "$BACKUP_DIR" == */ ]]; then
    BACKUP_DIR="${BACKUP_DIR%/}"  # Remove trailing slash if it exists
fi
# If BACKUP_DIR_WEEKLY ends with a slash, remove it
if [[ "$BACKUP_DIR_WEEKLY" == */ ]]; then
    BACKUP_DIR_WEEKLY="${BACKUP_DIR_WEEKLY%/}"  # Remove trailing slash if it exists
fi
# If SOURCE_DIR ends with a slash, remove it
if [[ "$SOURCE_DIR" == */ ]]; then
    SOURCE_DIR="${SOURCE_DIR%/}"  # Remove trailing slash if it exists
fi

# Define backup sync directory if it does not exist
BACKUP_SYNC_DIR="$BACKUP_DIR/sync"

# Ensure 7z is installed
if ! command -v 7z &>/dev/null; then
    echo "7z command not found. Please install 7zip package."
    echo "On Debian/Ubuntu, you can install it with: sudo apt install 7zip"
    sudo apt install -y 7zip
    if [ $? -ne 0 ]; then
        echo "Failed to install 7zip. Exiting."
        exit 1
    fi
fi

if [ -d "$SOURCE_DIR" ]; then
    echo "Source folder: $SOURCE_DIR"
else
    echo "Source folder does not exist: $SOURCE_DIR"
    mkdir -p "$SOURCE_DIR"
    echo "Created $SOURCE_DIR"
fi

if [ ! -d "$BACKUP_DIR" ]; then
    echo "Destination backup folder does not exist. Creating"
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$BACKUP_SYNC_DIR"
    echo "Created: $BACKUP_DIR"
    echo "Created: $BACKUP_SYNC_DIR "
fi

# Cleanup function to unmount shares and remove empty directories on script exit
cleanup() {
    echo "$SOURCE_DIR: Unmounting all shares"
    find "$SOURCE_DIR/" -type d -exec mountpoint -q {} \; -exec sudo umount -t cifs {} \;
    echo "$SOURCE_DIR: Removing empty folders"
    find "$SOURCE_DIR/" -type d -empty -delete
}
trap cleanup EXIT

# Cleanup previous mounts
echo "Cleaning up previous mounts in $SOURCE_DIR"
cleanup

# Get list of avaialble shares (ignore administrative shares)
SHARES=$(smbclient -L //$NAS_IP -U "$NAS_USER%$NAS_PASSWORD" | grep "Disk" | grep -v "\\$" | awk '{print $1}')

# Mounting shares
for SHARE in $SHARES; do
    MOUNT_POINT="$SOURCE_DIR/$SHARE"
    echo "Mounting NAS share: $SHARE at $MOUNT_POINT"
    mkdir -p "$SOURCE_DIR/$SHARE"
    sudo mount -t cifs "//$NAS_IP/$SHARE" "$MOUNT_POINT" \
    -o username="$NAS_USER",password="$NAS_PASSWORD",vers=$SMBVERSION,noperm
done

echo "All shares mounted successfully"
ls -al "$SOURCE_DIR"

# Start rsync backup from SOURCE_DIR/ to BACKUP_SYNC_DIR/
echo "Starting rsync backup from $SOURCE_DIR/ to $BACKUP_SYNC_DIR/"
rsync -zar --delete "$SOURCE_DIR/" "$BACKUP_SYNC_DIR/"
if [ $? -ne 0 ]; then
    echo "Rsync failed. Exiting."
    exit 1
fi
echo "Rsync completed successfully"
echo "Starting backup process"

# Check if today is Friday (5th day of the week)
# If today is Friday, create a 7z archive of the synced shares
# and store it in the backup directory
echo "Checking if today is Friday for weekly backup"

if [ "$(date +%u)" -eq 5 ]; then
    echo "Today is Friday, creating weekly backup"
    if [ -n "$BACKUP_DIR_WEEKLY" ] && [ -d "$BACKUP_DIR_WEEKLY" ]; then
        # Move old weekly backups to $BACKUP_DIR_WEEKLY
        find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type f -name '*.7z' -mtime +5 -exec mv {} "$BACKUP_DIR_WEEKLY/" \;
        echo "$BACKUP_DIR: Old weekly backups moved to $BACKUP_DIR_WEEKLY"
        # Remove backups older than 30 days
        echo "Removing weekly backups older than 30 days."
        find "$BACKUP_DIR_WEEKLY/" -mindepth 1 -maxdepth 1 -type f -name '*.7z' -mtime +30 -exec rm {} \;
        echo "$BACKUP_DIR_WEEKLY: Weekly backups older than 30 days have been removed"
    fi
    # For each folder (synced share) in $BACKUP_SYNC_DIR , create a 7z archive in $BACKUP_DIR
    # Check folders in $BACKUP_SYNC_DIR
    FOLDERS=$(find "$BACKUP_SYNC_DIR"  -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)
    if [ -z "$FOLDERS" ]; then
        echo "No folders found in $BACKUP_SYNC_DIR . Skipping 7z archive creation."
    else
        echo "Folders found: $FOLDERS"
        echo "Creating 7z archives for shares in $BACKUP_DIR"
        for FOLDER in $FOLDERS; do
            echo "Creating 7z archive for share: $FOLDER"
            7z a -t7z -mx=9 -mmt=on "$BACKUP_DIR/$FOLDER.7z" "$BACKUP_SYNC_DIR/$FOLDER"
        done
    fi
fi

echo "Backup completed successfully"

echo "Backup directory: $BACKUP_DIR"
echo "Backup source/NAS sync directory: $BACKUP_SYNC_DIR "
echo "Source directory: $SOURCE_DIR"

echo "Backup completed successfully"
echo "Backup script finished"

# End of script
