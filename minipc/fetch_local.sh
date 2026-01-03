set -ex

UUID=FA3D-8377
DISK_PATH=$(findmnt -noTARGET "/dev/disk/by-uuid/$UUID")

RESTIC_REPOSITORY=$DISK_PATH/home/restic-repo

PASSWORD_FILE=/run/secrets/restic_local_configuration
if [ -f "$PASSWORD_FILE" ]; then
    export $(cat "$PASSWORD_FILE" | xargs)
else
    echo "Password file not found, enter password: "
    read password
    export RESTIC_PASSWORD=$password
fi

echo $PASSWORD_FILE

MOUNTPOINT=/tmp/restic
mkdir -p $MOUNTPOINT

TAGS_FOLDER=$MOUNTPOINT/tags
DATA_PATH=mnt/storage_drive/sftp_chroot/data

restic -r $RESTIC_REPOSITORY mount $MOUNTPOINT &
while [ ! -d $MOUNTPOINT/tags/ ]; do
    sleep 1
done

trap "umount $MOUNTPOINT" EXIT

tags="Documenti Immagini miniflux postgresql Video"

for tag in $tags; do
    local_folder="/mnt/private_data/data/$tag"
    mkdir -p $local_folder

    backup_folder="$MOUNTPOINT/tags/$tag/latest/$DATA_PATH/$tag/"
    if [ ! -d $backup_folder ]; then
	backup_folder="$MOUNTPOINT/tags/$tag/latest/"
    fi

    rsync --verbose --delete --update --times --recursive $backup_folder $local_folder
done
