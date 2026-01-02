#!/usr/bin/env bash

set -xe

MAPPER_NAME=private_data
ENCRYPTED_PARTITION=/dev/sda3
MOUNTPOINT="/mnt/$MAPPER_NAME"

cryptsetup open "$ENCRYPTED_PARTITION" "$MAPPER_NAME"
mkdir -p "$MOUNTPOINT"
mount "/dev/mapper/$MAPPER_NAME" "$MOUNTPOINT"

ln -s "$MOUNTPOINT/data" ~/Desktop/"$MAPPER_NAME"

set +xe

echo "Use this command to close the partition"
echo "umount $MOUNTPOINT"
echo "cryptsetup close $MAPPER_NAME"
