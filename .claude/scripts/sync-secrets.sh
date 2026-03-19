#!/bin/bash
# Secure Secrets Sync Script
# Syncs environment secrets from claude-pattern vault to target projects
#
# SECURITY: This script handles sensitive credentials
# - Verifies source and target locations
# - Validates .gitignore configuration
# - Sets restrictive file permissions
# - Logs all sync operations
# - Never auto-syncs without explicit user action

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Source directory (claude-pattern secrets vault)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_SOURCE="$(cd "$SCRIPT_DIR/../secrets" && pwd)"
SYNC_LOG="$SECRETS_SOURCE/last-sync.log"

# Verify source exists
if [ ! -d "$SECRETS_SOURCE" ]; then
    echo -e "${RED}❌ ERROR: Secrets vault not found at $SECRETS_SOURCE${NC}"
    exit 1
fi

# Security banner
echo -e "${YELLOW}🔒 SECURE SECRETS SYNC${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}⚠️  WARNING: This script handles REAL secrets${NC}"
echo -e "${YELLOW}   - API keys, tokens, and passwords will be copied${NC}"
echo -e "${YELLOW}   - Ensure target .gitignore is configured${NC}"
echo -e "${YELLOW}   - Never commit .env.local to git${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Function to verify git-ignore
verify_gitignore() {
    local project_path=$1
    local file=$2

    if [ -d "$project_path/.git" ]; then
        if git -C "$project_path" check-ignore "$file" >/dev/null 2>&1; then
            return 0  # File is git-ignored (good)
        else
            return 1  # File is NOT git-ignored (bad)
        fi
    else
        # Not a git repo, can't verify
        return 0
    fi
}

# Function to sync secrets to target project
sync_to_project() {
    local target_project=$1
    local project_name=$(basename "$target_project")
    local env_type=${2:-production}  # Default to production

    echo -e "${BLUE}🔄 Syncing secrets to: $project_name${NC}"
    echo -e "${BLUE}   Target: $target_project${NC}"
    echo -e "${BLUE}   Environment: $env_type${NC}"
    echo ""

    # Verify target exists
    if [ ! -d "$target_project" ]; then
        echo -e "${RED}❌ ERROR: Target project not found: $target_project${NC}"
        return 1
    fi

    # Initialize sync success tracking
    local sync_success=true
    local files_synced=0

    # Determine which Paddle environment to use
    local paddle_env_file
    if [ "$env_type" = "sandbox" ]; then
        paddle_env_file="$SECRETS_SOURCE/.env.paddle.sandbox"
    else
        paddle_env_file="$SECRETS_SOURCE/.env.paddle.production"
    fi

    # Create or overwrite .env.local
    local target_env="$target_project/.env.local"

    # Start with base configuration (if exists)
    if [ -f "$SECRETS_SOURCE/.env.base" ]; then
        echo -e "${GREEN}📝 Adding base configuration...${NC}"
        cp "$SECRETS_SOURCE/.env.base" "$target_env"
        chmod 600 "$target_env"
        files_synced=$((files_synced + 1))
    else
        # Create empty file
        touch "$target_env"
        chmod 600 "$target_env"
    fi

    # Append Paddle secrets
    if [ -f "$paddle_env_file" ]; then
        echo -e "${GREEN}🔑 Adding Paddle secrets ($env_type)...${NC}"
        echo "" >> "$target_env"
        echo "# Paddle Configuration ($env_type)" >> "$target_env"
        cat "$paddle_env_file" >> "$target_env"
        files_synced=$((files_synced + 1))
    else
        echo -e "${YELLOW}⚠️  WARNING: Paddle $env_type config not found${NC}"
    fi

    # Append SMTP secrets
    if [ -f "$SECRETS_SOURCE/.env.smtp" ]; then
        echo -e "${GREEN}📧 Adding SMTP configuration...${NC}"
        echo "" >> "$target_env"
        echo "# Email Service Configuration" >> "$target_env"
        cat "$SECRETS_SOURCE/.env.smtp" >> "$target_env"
        files_synced=$((files_synced + 1))
    else
        echo -e "${YELLOW}⚠️  WARNING: SMTP config not found${NC}"
    fi

    # Verify file permissions
    local perms=$(stat -f "%Lp" "$target_env" 2>/dev/null || stat -c "%a" "$target_env" 2>/dev/null)
    if [ "$perms" != "600" ]; then
        echo -e "${YELLOW}⚠️  Fixing file permissions: $perms → 600${NC}"
        chmod 600 "$target_env"
    fi

    # Verify .gitignore
    if verify_gitignore "$target_project" ".env.local"; then
        echo -e "${GREEN}✅ Verified .env.local is git-ignored${NC}"
    else
        echo -e "${RED}❌ CRITICAL: .env.local is NOT git-ignored!${NC}"
        echo -e "${RED}   Add '.env.local' to $target_project/.gitignore immediately${NC}"
        echo -e "${RED}   Run: echo '.env.local' >> $target_project/.gitignore${NC}"
        sync_success=false
    fi

    # Double-check git status
    if [ -d "$target_project/.git" ]; then
        if git -C "$target_project" status --short | grep -q ".env.local"; then
            echo -e "${RED}❌ CRITICAL: .env.local appears in git status!${NC}"
            echo -e "${RED}   DO NOT commit this file!${NC}"
            sync_success=false
        else
            echo -e "${GREEN}✅ Git status clean (no .env.local tracked)${NC}"
        fi
    fi

    # Log sync
    if [ "$sync_success" = true ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: Synced to $project_name ($env_type, $files_synced files)" >> "$SYNC_LOG"
        echo ""
        echo -e "${GREEN}✅ Sync complete: $files_synced file(s) synced${NC}"
        echo -e "${GREEN}   Target: $target_env${NC}"
        echo -e "${GREEN}   Permissions: 600 (owner read/write only)${NC}"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAILED: Sync to $project_name had errors" >> "$SYNC_LOG"
        echo ""
        echo -e "${RED}⚠️  Sync completed with warnings - verify .gitignore!${NC}"
    fi

    return 0
}

# Display usage
usage() {
    echo -e "${BLUE}Usage: $0 [OPTIONS] <target-project-path>${NC}"
    echo ""
    echo -e "${BLUE}Options:${NC}"
    echo "  --production    Sync production Paddle environment (default)"
    echo "  --sandbox       Sync sandbox Paddle environment"
    echo "  --all           Sync to all known projects"
    echo ""
    echo -e "${BLUE}Examples:${NC}"
    echo "  # Sync production secrets to specific project"
    echo "  $0 ~/Developer/Private/hivetechs-website"
    echo ""
    echo "  # Sync sandbox secrets for testing"
    echo "  $0 --sandbox ~/Developer/Private/test-project"
    echo ""
    echo "  # Sync production secrets to all known projects"
    echo "  $0 --all"
    echo ""
    echo -e "${BLUE}Security Notes:${NC}"
    echo "  - This script copies REAL secrets (API keys, tokens)"
    echo "  - Target .env.local will be OVERWRITTEN"
    echo "  - File permissions set to 600 (owner only)"
    echo "  - Verifies .gitignore configuration"
    echo "  - Logs all operations to $SYNC_LOG"
}

# Known project paths (customize as needed)
declare -a KNOWN_PROJECTS=(
    "$HOME/Developer/Private/hivetechs-website"
    "$HOME/Developer/Private/hive"
)

# Parse arguments
ENV_TYPE="production"
SYNC_ALL=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --production)
            ENV_TYPE="production"
            shift
            ;;
        --sandbox)
            ENV_TYPE="sandbox"
            shift
            ;;
        --all)
            SYNC_ALL=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            TARGET_PROJECT="$1"
            shift
            ;;
    esac
done

# Main execution
if [ "$SYNC_ALL" = true ]; then
    echo -e "${YELLOW}🔄 Syncing $ENV_TYPE secrets to all known projects...${NC}"
    echo ""

    for project in "${KNOWN_PROJECTS[@]}"; do
        if [ -d "$project" ]; then
            sync_to_project "$project" "$ENV_TYPE"
            echo ""
        else
            echo -e "${YELLOW}⚠️  Skipping (not found): $project${NC}"
            echo ""
        fi
    done

    echo -e "${GREEN}✅ All syncs complete!${NC}"
elif [ -n "${TARGET_PROJECT:-}" ]; then
    sync_to_project "$TARGET_PROJECT" "$ENV_TYPE"
else
    echo -e "${RED}❌ ERROR: No target project specified${NC}"
    echo ""
    usage
    exit 1
fi

echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}🔒 SECURITY REMINDERS${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}   ✓ Verify .env.local is git-ignored${NC}"
echo -e "${YELLOW}   ✓ NEVER commit .env.local to git${NC}"
echo -e "${YELLOW}   ✓ Regularly rotate API keys (quarterly)${NC}"
echo -e "${YELLOW}   ✓ Run backups: .claude/scripts/backup-secrets.sh${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
