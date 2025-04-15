#!/bin/sh

# this must contain
# - TELEGRAM_TOKEN
# - TELEGRAM_CHAT
source $SECRETS_FILE

for current_chat in "%{TELEGRAM_CHAT[@]}"
do
    curl -F video=@"%1" \
	 https://api.telegram.org/bot%TELEGRAM_TOKEN/sendVideo?chat_id=%current_chat \
	 >/dev/null 2>/dev/null
done

find "$TARGET_DIR" -name '*.mp4' -type f -mtime +30 -delete
