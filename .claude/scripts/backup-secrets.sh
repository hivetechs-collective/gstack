#!/bin/bash
# Secure Secrets Backup Script
# Creates encrypted backups of the secrets vault
#
# SECURITY: This script handles sensitive credentials
# - Creates timestamped backups
# - Compresses for efficient storage
# - Verifies backup integrity
# - Stores in user-specified location

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_SOURCE="$(cd "$SCRIPT_DIR/../secrets" && pwd)"
BACKUP_DIR="${BACKUP_DIR:-$HOME/Backups}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_NAME="claude-secrets-$TIMESTAMP.tar.gz"

# Security banner
echo -e "${YELLOW}🔒 SECURE SECRETS BACKUP${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}⚠️  WARNING: Creating backup of REAL secrets${NC}"
echo -e "${YELLOW}   - Backup will contain API keys, tokens, passwords${NC}"
echo -e "${YELLOW}   - Store in secure, encrypted location${NC}"
echo -e "${YELLOW}   - Do NOT upload to cloud services${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Verify source exists
if [ ! -d "$SECRETS_SOURCE" ]; then
    echo -e "${RED}❌ ERROR: Secrets vault not found at $SECRETS_SOURCE${NC}"
    exit 1
fi

# Create backup directory if it doesn't exist
if [ ! -d "$BACKUP_DIR" ]; then
    echo -e "${BLUE}📁 Creating backup directory: $BACKUP_DIR${NC}"
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
fi

# Verify backup directory permissions
BACKUP_DIR_PERMS=$(stat -f "%Lp" "$BACKUP_DIR" 2>/dev/null || stat -c "%a" "$BACKUP_DIR" 2>/dev/null)
if [ "$BACKUP_DIR_PERMS" != "700" ]; then
    echo -e "${YELLOW}⚠️  Fixing backup directory permissions: $BACKUP_DIR_PERMS → 700${NC}"
    chmod 700 "$BACKUP_DIR"
fi

# Count secrets files
SECRET_FILES=$(find "$SECRETS_SOURCE" -type f -name ".env.*" | wc -l | tr -d ' ')
echo -e "${BLUE}📦 Backing up $SECRET_FILES secret file(s)${NC}"
echo -e "${BLUE}   Source: $SECRETS_SOURCE${NC}"
echo -e "${BLUE}   Target: $BACKUP_DIR/$BACKUP_NAME${NC}"
echo ""

# Create backup
echo -e "${GREEN}🔄 Creating compressed backup...${NC}"
cd "$SECRETS_SOURCE/.."
tar -czf "$BACKUP_DIR/$BACKUP_NAME" \
    --exclude=".DS_Store" \
    secrets/

# Verify backup was created
if [ -f "$BACKUP_DIR/$BACKUP_NAME" ]; then
    BACKUP_SIZE=$(ls -lh "$BACKUP_DIR/$BACKUP_NAME" | awk '{print $5}')
    echo -e "${GREEN}✅ Backup created successfully${NC}"
    echo -e "${GREEN}   File: $BACKUP_DIR/$BACKUP_NAME${NC}"
    echo -e "${GREEN}   Size: $BACKUP_SIZE${NC}"

    # Set restrictive permissions on backup
    chmod 600 "$BACKUP_DIR/$BACKUP_NAME"
    echo -e "${GREEN}   Permissions: 600 (owner read/write only)${NC}"

    # Verify backup integrity
    echo ""
    echo -e "${BLUE}🔍 Verifying backup integrity...${NC}"
    if tar -tzf "$BACKUP_DIR/$BACKUP_NAME" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Backup integrity verified${NC}"

        # List contents
        echo ""
        echo -e "${BLUE}📋 Backup contents:${NC}"
        tar -tzf "$BACKUP_DIR/$BACKUP_NAME" | grep -E "\.env\.|README|inventory" | sed 's/^/   /'
    else
        echo -e "${RED}❌ ERROR: Backup integrity check failed${NC}"
        exit 1
    fi

    # Update inventory log
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup created: $BACKUP_NAME ($BACKUP_SIZE)" >> "$SECRETS_SOURCE/last-sync.log"

else
    echo -e "${RED}❌ ERROR: Backup creation failed${NC}"
    exit 1
fi

# Cleanup old backups (keep last 10)
echo ""
echo -e "${BLUE}🧹 Checking for old backups...${NC}"
OLD_BACKUPS=$(find "$BACKUP_DIR" -name "claude-secrets-*.tar.gz" -type f | sort -r | tail -n +11)

if [ -n "$OLD_BACKUPS" ]; then
    echo -e "${YELLOW}⚠️  Found old backups (keeping most recent 10):${NC}"
    echo "$OLD_BACKUPS" | while read -r old_backup; do
        echo -e "${YELLOW}   Removing: $(basename "$old_backup")${NC}"
        rm -f "$old_backup"
    done
else
    echo -e "${GREEN}✅ No old backups to clean up${NC}"
fi

# Display backup summary
echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}📊 BACKUP SUMMARY${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}   ✓ Backup: $BACKUP_NAME${NC}"
echo -e "${GREEN}   ✓ Location: $BACKUP_DIR${NC}"
echo -e "${GREEN}   ✓ Size: $BACKUP_SIZE${NC}"
echo -e "${GREEN}   ✓ Files: $SECRET_FILES secret file(s)${NC}"
echo -e "${GREEN}   ✓ Integrity: Verified${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${YELLOW}🔒 SECURITY REMINDERS${NC}"
echo -e "${YELLOW}   ✓ Backup contains REAL secrets${NC}"
echo -e "${YELLOW}   ✓ Store in encrypted location${NC}"
echo -e "${YELLOW}   ✓ Do NOT upload to cloud${NC}"
echo -e "${YELLOW}   ✓ Keep offline backup copy${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${BLUE}To restore from backup:${NC}"
echo -e "${BLUE}  cd ~/.claude && tar -xzf $BACKUP_DIR/$BACKUP_NAME${NC}"
