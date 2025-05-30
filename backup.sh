#!/bin/bash
# Author: Paweł 'felixd' Wojciechowski
# (c) 2025 - FlameIT - Immersion Cooling

# Default .env settings
# NAS_IP="127.0.0.1"   # NAS IP address
# NAS Mount point
# SOURCE_DIR="/mnt/source"
# Backup directory
# BACKUP_DIR="/mnt/backup"
# NAS_USER="backup"
# NAS_PASSWORD=""

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

if [ -d $SOURCE_DIR ]; then
    echo "Source folder: $SOURCE_DIR"
else
    echo "Source folder does not exist: $SOURCE_DIR"
    mkdir -p $SOURCE_DIR
    echo "Created $SOURCE_DIR"
fi

if [ ! -d $BACKUP_DIR ]; then
    echo "Destination backup folder does not exist. Creating"
    mkdir -p $BACKUP_DIR
fi

echo "$SOURCE_DIR: Unmouning all CIFS type directories"
find $SOURCE_DIR -type d -exec mountpoint -q {} \; -exec umount -t cifs {} \;

echo "$SOURCE_DIR: Removing empty folders"
find $SOURCE_DIR/ -type d -empty -delete

# Get list of avaialble shares (ignore administrative shares)
SHARES=$(smbclient -L //$NAS_IP -U "$NAS_USER%$NAS_PASSWORD" | grep "Disk" | grep -v "\\$" | awk '{print $1}')

# Mounting shares
for SHARE in $SHARES; do
    MOUNT_POINT="$SOURCE_DIR/$SHARE"
    echo "Mounting NAS share: $SHARE at $MOUNT_POINT"
    mkdir -p "$SOURCE_DIR/$SHARE"
    mount -t cifs "//$NAS_IP/$SHARE" "$MOUNT_POINT" \
        -o username="$NAS_USER",password="$NAS_PASSWORD",vers=$SMBVERSION,uid=1000,gid=1000,noperm
done

rsync -zar --delete $SOURCE_DIR $BACKUP_DIR
if [ $? -ne 0 ]; then
    echo "Rsync failed. Exiting."
    exit 1
fi
echo "Rsync completed successfully"
echo "Starting backup process"

if [ "$(date +%u)" -eq 5 ]; then
    echo "Today is Friday, creating weekly backup"
    
    # For each folder in $BACKUP_DIR, create a 7z archive
    # Check folders in $BACKUP_DIR   
    FOLDERS=$(find $BACKUP_DIR -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)
    if [ -z "$FOLDERS" ]; then
        echo "No shares found in $BACKUP_DIR. Skipping 7z archive creation."
        exit 0
    fi
    echo "Shares found: $FOLDERS"
    echo "Creating 7z archives for shares in $BACKUP_DIR"
    # Ensure 7z is installed
    if ! command -v 7z &> /dev/null; then
        echo "7z command not found. Please install p7zip-full package."
        exit 1
    fi    
    for FOLDER in $FOLDERS; do
        echo "Creating 7z archive for share: $FOLDER"
        7z a -t7z -mx=9 -mmt=on $BACKUP_DIR/$FOLDER.7z $BACKUP_DIR/$FOLDER
    done
fi

echo "Backup completed successfully"
echo "Unmounting all shares"
find $SOURCE_DIR -type d -exec mountpoint -q {} \; -exec umount -t cifs {} \;
echo "Removing empty folders"
find $SOURCE_DIR/ -type d -empty -delete
echo "Backup directory: $BACKUP_DIR"
echo "Backup source directory: $SOURCE_DIR"
echo "Backup completed successfully"
echo "Backup script finished"
