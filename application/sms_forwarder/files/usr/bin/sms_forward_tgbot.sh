#!/bin/sh

# Telegram Bot SMS Forward Script
# Environment variables available:
# SMS_SENDER - sender phone number
# SMS_TIME - timestamp string
# SMS_CONTENT - SMS content

# Parse API config from environment or config file
API_CONFIG="$1"

if [ -z "$API_CONFIG" ]; then
    echo "Error: API config not provided"
    exit 1
fi

# Extract configuration
BOT_TOKEN=$(echo "$API_CONFIG" | grep -o '"bot_token":"[^"]*"' | cut -d'"' -f4)
CHAT_ID=$(echo "$API_CONFIG" | grep -o '"chat_id":"[^"]*"' | cut -d'"' -f4)

if [ -z "$BOT_TOKEN" ] || [ -z "$CHAT_ID" ]; then
    echo "Error: Missing required Telegram Bot configuration"
    exit 1
fi

# Prepare message
MESSAGE="📱 New SMS Message

📞 From: $SMS_SENDER
🕒 Time: $SMS_TIME
💬 Content: $SMS_CONTENT"

# URL encode the message
MESSAGE_ENCODED=$(echo "$MESSAGE" | sed 's/ /%20/g; s/\n/%0A/g; s/📱/%F0%9F%93%B1/g; s/📞/%F0%9F%93%9E/g; s/🕒/%F0%9F%95%92/g; s/💬/%F0%9F%92%AC/g')

# Telegram API URL
TG_URL="https://api.telegram.org/bot$BOT_TOKEN/sendMessage"

# Try curl first, then wget
if command -v curl >/dev/null 2>&1; then
    curl -X POST "$TG_URL" \
        -d "chat_id=$CHAT_ID" \
        -d "text=$MESSAGE_ENCODED" \
        -d "parse_mode=HTML" \
        --connect-timeout 10 \
        --max-time 30
elif command -v wget >/dev/null 2>&1; then
    wget -O- \
        --post-data="chat_id=$CHAT_ID&text=$MESSAGE_ENCODED&parse_mode=HTML" \
        --timeout=30 \
        "$TG_URL"
else
    echo "Error: Neither curl nor wget available"
    exit 1
fi

exit $?
