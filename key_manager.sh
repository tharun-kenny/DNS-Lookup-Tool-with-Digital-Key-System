#!/bin/bash

############################################################
# Digital Key Manager for DNS Lookup Tool
# Manages encryption keys, audit logs, and access control
############################################################

# Configuration
KEY_DIR="$(dirname "$0")/keys"
LOG_DIR="$(dirname "$0")/logs"
MASTER_KEY_FILE="${KEY_DIR}/master.key"
USER_KEYS_FILE="${KEY_DIR}/user_keys.enc"
ACCESS_LOG="${LOG_DIR}/access_$(date +%Y%m%d).log"
KEY_EXPIRY_DAYS=7

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Initialize key system
init_key_system() {
    mkdir -p "$KEY_DIR"
    mkdir -p "$LOG_DIR"
    
    if [ ! -f "$MASTER_KEY_FILE" ]; then
        echo -e "${YELLOW}Initializing new key system...${NC}"
        # Generate master key
        openssl rand -base64 32 > "$MASTER_KEY_FILE"
        chmod 600 "$MASTER_KEY_FILE"
        
        # Create empty user keys file
        touch "$USER_KEYS_FILE"
        chmod 600 "$USER_KEYS_FILE"
        
        echo -e "${GREEN}Key system initialized${NC}"
        log_access "SYSTEM_INIT" "New key system created"
    fi
}

# Log access attempts
log_access() {
    local action="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local user=$(whoami)
    local host=$(hostname)
    
    echo "[$timestamp] [$action] [$user@$host] $message" >> "$ACCESS_LOG"
}

# Generate new key
generate_key() {
    local key_id="KEY_$(date +%Y%m%d%H%M%S)_$(openssl rand -hex 4)"
    local key_secret=$(openssl rand -base64 24)
    local expiry_date=$(date -d "+$KEY_EXPIRY_DAYS days" +%Y-%m-%d)
    
    # Encrypt the key
    local master_key=$(cat "$MASTER_KEY_FILE")
    local encrypted_key=$(echo -n "$key_secret:$expiry_date" | openssl enc -aes-256-cbc -base64 -pass pass:"$master_key")
    
    # Store encrypted key
    echo "$key_id:$encrypted_key" >> "$USER_KEYS_FILE"
    
    echo -e "${GREEN}New key generated:${NC}"
    echo "Key ID: $key_id"
    echo "Key Secret: $key_secret"
    echo "Expires: $expiry_date"
    echo ""
    echo -e "${YELLOW}⚠️ Save this key securely - it won't be shown again!${NC}"
    
    log_access "KEY_GENERATE" "Generated new key: $key_id"
    
    # Return just the key ID for scripts
    echo "$key_id"
}

# Validate key
validate_key() {
    local key_id="$1"
    local key_secret="$2"
    
    if [ ! -f "$USER_KEYS_FILE" ]; then
        return 1
    fi
    
    local master_key=$(cat "$MASTER_KEY_FILE")
    local key_entry=$(grep "^$key_id:" "$USER_KEYS_FILE")
    
    if [ -z "$key_entry" ]; then
        log_access "KEY_VALIDATE" "FAILED - Key ID not found: $key_id"
        return 1
    fi
    
    local encrypted_data=$(echo "$key_entry" | cut -d: -f2-)
    local decrypted_data=$(echo "$encrypted_data" | openssl enc -d -aes-256-cbc -base64 -pass pass:"$master_key" 2>/dev/null)
    
    if [ $? -ne 0 ]; then
        log_access "KEY_VALIDATE" "FAILED - Decryption error for: $key_id"
        return 1
    fi
    
    local stored_secret=$(echo "$decrypted_data" | cut -d: -f1)
    local expiry_date=$(echo "$decrypted_data" | cut -d: -f2)
    local current_date=$(date +%Y-%m-%d)
    
    # Check if key matches
    if [ "$stored_secret" != "$key_secret" ]; then
        log_access "KEY_VALIDATE" "FAILED - Invalid secret for: $key_id"
        return 1
    fi
    
    # Check expiry
    if [[ "$current_date" > "$expiry_date" ]]; then
        log_access "KEY_VALIDATE" "FAILED - Key expired: $key_id"
        echo "EXPIRED"
        return 1
    fi
    
    log_access "KEY_VALIDATE" "SUCCESS - Valid key: $key_id"
    echo "VALID"
    return 0
}

# Unlock system
unlock_system() {
    echo -e "${BLUE}Digital Key System Unlock${NC}"
    echo "============================="
    
    if [ -f "/tmp/dns_key.active" ]; then
        echo -e "${GREEN}System is already unlocked${NC}"
        return 0
    fi
    
    local attempts=0
    local max_attempts=3
    
    while [ $attempts -lt $max_attempts ]; do
        echo ""
        read -p "Enter Key ID: " key_id
        read -sp "Enter Key Secret: " key_secret
        echo ""
        
        local result=$(validate_key "$key_id" "$key_secret")
        
        if [ "$result" = "VALID" ]; then
            # Create unlock file with expiry
            local unlock_file="/tmp/dns_key.active"
            echo "KEY_ID=$key_id" > "$unlock_file"
            echo "UNLOCK_TIME=$(date +%s)" >> "$unlock_file"
            echo "USER=$(whoami)" >> "$unlock_file"
            chmod 600 "$unlock_file"
            
            echo -e "\n${GREEN}✅ System unlocked successfully!${NC}"
            log_access "SYSTEM_UNLOCK" "SUCCESS - Key: $key_id"
            
            # Start auto-lock timer (8 hours)
            (
                sleep 28800
                lock_system_auto
            ) &
            
            return 0
        elif [ "$result" = "EXPIRED" ]; then
            echo -e "${RED}❌ Key has expired${NC}"
            log_access "SYSTEM_UNLOCK" "FAILED - Expired key: $key_id"
            return 1
        else
            attempts=$((attempts + 1))
            local remaining=$((max_attempts - attempts))
            echo -e "${RED}❌ Invalid key. Attempts remaining: $remaining${NC}"
            log_access "SYSTEM_UNLOCK" "FAILED - Attempt $attempts for key: $key_id"
        fi
    done
    
    echo -e "${RED}🔒 Maximum attempts reached. System locked.${NC}"
    log_access "SYSTEM_LOCKOUT" "Maximum unlock attempts reached"
    touch "/tmp/dns_tool.lock"
    return 1
}

# Lock system
lock_system() {
    echo -e "${YELLOW}Locking system...${NC}"
    
    if [ -f "/tmp/dns_key.active" ]; then
        local key_id=$(grep "KEY_ID" "/tmp/dns_key.active" | cut -d= -f2)
        log_access "SYSTEM_LOCK" "Manual lock - Key: $key_id"
        rm -f "/tmp/dns_key.active"
    fi
    
    rm -f "/tmp/dns_tool.lock"
    echo -e "${GREEN}✅ System locked${NC}"
}

# Auto-lock system
lock_system_auto() {
    if [ -f "/tmp/dns_key.active" ]; then
        local key_id=$(grep "KEY_ID" "/tmp/dns_key.active" | cut -d= -f2)
        log_access "SYSTEM_LOCK" "Auto-lock after timeout - Key: $key_id"
        rm -f "/tmp/dns_key.active"
        echo -e "${YELLOW}System auto-locked after 8 hours${NC}" >&2
    fi
}

# Check if system is unlocked
check_status() {
    if [ -f "/tmp/dns_key.active" ]; then
        local key_id=$(grep "KEY_ID" "/tmp/dns_key.active" | cut -d= -f2)
        local unlock_time=$(grep "UNLOCK_TIME" "/tmp/dns_key.active" | cut -d= -f2)
        local current_time=$(date +%s)
        local unlocked_for=$((current_time - unlock_time))
        local unlocked_hours=$((unlocked_for / 3600))
        local unlocked_minutes=$(((unlocked_for % 3600) / 60))
        
        echo -e "${GREEN}Status: UNLOCKED${NC}"
        echo "Key ID: $key_id"
        echo "Unlocked for: ${unlocked_hours}h ${unlocked_minutes}m"
        echo "Auto-lock in: $((8 - unlocked_hours)) hours"
        return 0
    else
        echo -e "${RED}Status: LOCKED${NC}"
        return 1
    fi
}

# Log key usage
log_key_usage() {
    local action="$1"
    
    if [ -f "/tmp/dns_key.active" ]; then
        local key_id=$(grep "KEY_ID" "/tmp/dns_key.active" | cut -d= -f2)
        log_access "KEY_USAGE" "Action: $action - Key: $key_id"
    fi
}

# List all keys
list_keys() {
    echo -e "${BLUE}Registered Keys:${NC}"
    echo "================="
    
    if [ ! -s "$USER_KEYS_FILE" ]; then
        echo "No keys found"
        return
    fi
    
    local master_key=$(cat "$MASTER_KEY_FILE")
    
    while IFS=: read -r key_id encrypted_data; do
        local decrypted_data=$(echo "$encrypted_data" | openssl enc -d -aes-256-cbc -base64 -pass pass:"$master_key" 2>/dev/null)
        
        if [ $? -eq 0 ]; then
            local expiry_date=$(echo "$decrypted_data" | cut -d: -f2)
            local status="ACTIVE"
            local current_date=$(date +%Y-%m-%d)
            
            if [[ "$current_date" > "$expiry_date" ]]; then
                status="EXPIRED"
            fi
            
            echo "• $key_id"
            echo "  Expiry: $expiry_date"
            echo "  Status: $status"
            echo ""
        fi
    done < "$USER_KEYS_FILE"
}

# Revoke a key
revoke_key() {
    local key_id="$1"
    
    if [ -z "$key_id" ]; then
        echo -e "${RED}Error: Key ID required${NC}"
        echo "Usage: $0 --revoke <key_id>"
        return 1
    fi
    
    if grep -q "^$key_id:" "$USER_KEYS_FILE"; then
        # Create backup
        cp "$USER_KEYS_FILE" "${USER_KEYS_FILE}.bak"
        
        # Remove key
        grep -v "^$key_id:" "$USER_KEYS_FILE" > "${USER_KEYS_FILE}.tmp"
        mv "${USER_KEYS_FILE}.tmp" "$USER_KEYS_FILE"
        
        echo -e "${GREEN}Key revoked: $key_id${NC}"
        log_access "KEY_REVOKE" "Key revoked: $key_id"
        
        # If this was the active key, lock system
        if [ -f "/tmp/dns_key.active" ]; then
            local active_key=$(grep "KEY_ID" "/tmp/dns_key.active" | cut -d= -f2)
            if [ "$active_key" = "$key_id" ]; then
                lock_system
            fi
        fi
    else
        echo -e "${RED}Key not found: $key_id${NC}"
    fi
}

# Show usage
usage() {
    echo -e "${BLUE}Digital Key Manager${NC}"
    echo "===================="
    echo ""
    echo "Usage: $0 [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  --unlock           Unlock system with digital key"
    echo "  --lock             Lock the system"
    echo "  --status           Check system status"
    echo "  --generate         Generate new digital key"
    echo "  --list             List all keys"
    echo "  --revoke KEY_ID    Revoke a specific key"
    echo "  --check            Check if system is unlocked (for scripts)"
    echo "  --log-usage ACTION Log key usage"
    echo "  --help             Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 --generate"
    echo "  $0 --unlock"
    echo "  $0 --status"
    echo "  $0 --revoke KEY_20240101120000_abcd1234"
}

# Main execution
main() {
    init_key_system
    
    case "$1" in
        --unlock)
            unlock_system
            ;;
        --lock)
            lock_system
            ;;
        --status)
            check_status
            ;;
        --generate)
            generate_key
            ;;
        --list)
            list_keys
            ;;
        --revoke)
            revoke_key "$2"
            ;;
        --check)
            if check_status > /dev/null; then
                echo "VALID"
            else
                echo "LOCKED"
            fi
            ;;
        --log-usage)
            log_key_usage "$2"
            ;;
        --help|-h)
            usage
            ;;
        *)
            if [ $# -eq 0 ]; then
                usage
            else
                echo -e "${RED}Unknown command: $1${NC}"
                usage
                exit 1
            fi
            ;;
    esac
}

# Run main function
main "$@"
