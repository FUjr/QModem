#!/bin/sh

# Webhook SMS Forward Script
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

# Extract configuration using jq or manual parsing
WEBHOOK_URL=$(echo "$API_CONFIG" | jq -r '.webhook_url' 2>/dev/null)
HEADERS=$(echo "$API_CONFIG" | jq -r '.headers' 2>/dev/null)

# Fallback to manual parsing if jq fails
if [ -z "$WEBHOOK_URL" ] || [ "$WEBHOOK_URL" = "null" ]; then
    WEBHOOK_URL=$(echo "$API_CONFIG" | grep -o '"webhook_url":"[^"]*"' | cut -d'"' -f4)
fi

if [ -z "$HEADERS" ] || [ "$HEADERS" = "null" ]; then
    HEADERS=$(echo "$API_CONFIG" | grep -o '"headers":"[^"]*"' | cut -d'"' -f4)
fi

if [ -z "$WEBHOOK_URL" ]; then
    echo "Error: Missing required webhook URL"
    exit 1
fi

# Prepare JSON payload using jq if available
if command -v jq >/dev/null 2>&1; then
    JSON_PAYLOAD=$(jq -n \
        --arg type "sms" \
        --arg title "QModem SMS: ($SMS_SENDER)" \
        --arg timestamp "$SMS_TIME" \
        --arg sender "$SMS_SENDER" \
        --arg content "$SMS_CONTENT" \
        '{
            type: $type,
            title: $title,
            timestamp: $timestamp,
            sender: $sender,
            content: $content
        }')
else
    # Fallback JSON generation
    JSON_PAYLOAD="{
    \"type\": \"sms\",
    \"title\": \"QModem SMS: ($SMS_SENDER)\",
    \"timestamp\": \"$SMS_TIME\",
    \"sender\": \"$SMS_SENDER\",
    \"content\": \"$SMS_CONTENT\"
}"
fi

# Try curl first, then wget
if command -v curl >/dev/null 2>&1; then
    CURL_CMD="curl -X POST \"$WEBHOOK_URL\""
    CURL_CMD="$CURL_CMD -H \"Content-Type: application/json\""
    
    # Add custom headers if provided
    if [ -n "$HEADERS" ]; then
        CURL_CMD="$CURL_CMD -H \"$HEADERS\""
    fi
    
    CURL_CMD="$CURL_CMD -d '$JSON_PAYLOAD'"
    CURL_CMD="$CURL_CMD --connect-timeout 10 --max-time 30"
    
    eval "$CURL_CMD"
elif command -v wget >/dev/null 2>&1; then
    # Create temporary file for POST data
    TEMP_FILE=$(mktemp)
    echo "$JSON_PAYLOAD" > "$TEMP_FILE"
    
    WGET_CMD="wget -O-"
    WGET_CMD="$WGET_CMD --header=\"Content-Type: application/json\""
    
    # Add custom headers if provided
    if [ -n "$HEADERS" ]; then
        WGET_CMD="$WGET_CMD --header=\"$HEADERS\""
    fi
    
    WGET_CMD="$WGET_CMD --post-file=\"$TEMP_FILE\""
    WGET_CMD="$WGET_CMD --timeout=30"
    WGET_CMD="$WGET_CMD \"$WEBHOOK_URL\""
    
    eval "$WGET_CMD"
    rm -f "$TEMP_FILE"
else
    echo "Error: Neither curl nor wget available"
    exit 1
fi

exit $?
