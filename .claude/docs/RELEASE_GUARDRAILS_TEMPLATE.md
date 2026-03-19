# Universal Release Guardrails Template

**Version**: 1.0.0
**Source**: Extracted from Hive Consensus Beta Implementation
**Purpose**: Provide reusable release guardrails patterns for all HiveTechs repositories

---

## Executive Summary

This document templates the production-grade release guardrails implemented in the Hive Consensus repository. These patterns can be adapted for any project requiring:

- Multi-channel releases (beta/stable, canary/production)
- Quality gates with automated verification
- Branch governance enforcement
- Release orchestration with Claude agents

---

## 1. Architecture Overview

### Dual-Channel Release Model

```
┌─────────────────────────────────────────────────────┐
│                  SOURCE BRANCHES                     │
├─────────────────────────────────────────────────────┤
│   beta branch ──────────► Beta Channel              │
│                          - Tag: v1.8.xxx-beta       │
│                          - Pre-release flag         │
│                          - Separate package/cask    │
├─────────────────────────────────────────────────────┤
│   main/master branch ───► Stable Channel            │
│                          - Tag: v1.8.xxx            │
│                          - Standard release         │
│                          - Primary package/cask     │
└─────────────────────────────────────────────────────┘
```

### Quality Gate Pipeline

```
Gate 0.0: Pre-Flight Cleanup (kill stuck processes, remove artifacts)
    ↓
Gate 0: Version Validation (format, consistency check)
    ↓
Gate 0.5: Credential Pre-Check (verify auth before long build)
    ↓
Gate 1: Configuration Check (build/sign settings verified)
    ↓
Gate 2: Environment Check (clean state, no stale locks)
    ↓
Gate 3: Build Execution (compile, bundle, package)
    ↓
Gate 4: Post-Build Verification (signing, structure check)
    ↓
Gate 4.5: Version Consistency (version drift detection)
    ↓
Gate 5: External Verification (notarization, signing validation)
    ↓
Gate 6: Pre-Release Verification (final safety checks)
    ↓
Gate 7: Metadata Generation (checksums, release notes)
    ↓
Gate 8: Platform Release (GitHub/npm/etc.)
    ↓
Gate 9: Distribution Update (Homebrew/npm registry/etc.)
```

---

## 2. Gate Implementations

### Gate 0.0: Pre-Flight Cleanup (CRITICAL)

**Purpose**: Eliminate stuck processes and stale artifacts from previous releases

**Implementation**:
```bash
#!/bin/bash
# gate-0.0-cleanup.sh

echo "🧹 Gate 0.0: Pre-Flight Cleanup"

# 1. Kill stuck processes (adapt to your tech stack)
pkill -f "notarytool --wait" 2>/dev/null || true
pkill -f "npm publish" 2>/dev/null || true
pkill -f "build-script" 2>/dev/null || true

# 2. Remove build artifacts
rm -rf out/ dist/ build/ .cache/ node_modules/.cache 2>/dev/null || true

# 3. Remove version lock files
rm -f .version-lock-* .build-lock-* 2>/dev/null || true

# 4. Remove old release metadata
rm -f release-*-info.txt 2>/dev/null || true

# 5. Unmount any mounted volumes (macOS)
for volume in /Volumes/MyApp*; do
  hdiutil detach "$volume" -force 2>/dev/null || true
done

echo "✅ Gate 0.0: Cleanup complete"
```

**Key Benefits**:
- Prevents 42+ minute hangs from stuck processes
- Ensures every build starts fresh
- Eliminates "works on my machine" issues

### Gate 0: Version Validation

**Purpose**: Ensure version format and consistency before build

**Implementation**:
```bash
#!/bin/bash
# gate-0-version.sh

VERSION="$1"
MODE="${2:-pre-build}"  # pre-build or post-build

echo "📋 Gate 0: Version Validation (${MODE})"

# Validate version format
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-beta)?$ ]]; then
  echo "❌ Invalid version format: $VERSION"
  echo "   Expected: X.Y.Z or X.Y.Z-beta"
  exit 1
fi

if [[ "$MODE" == "pre-build" ]]; then
  # Check source files before build
  PACKAGE_VERSION=$(jq -r '.version' package.json)
  if [[ "$PACKAGE_VERSION" != "$VERSION" ]]; then
    echo "❌ Version mismatch: package.json=$PACKAGE_VERSION, expected=$VERSION"
    exit 1
  fi
fi

echo "✅ Gate 0: Version validation passed"
```

### Gate 0.5: Credential Pre-Check

**Purpose**: Verify authentication before starting long-running build

**Implementation**:
```bash
#!/bin/bash
# gate-0.5-credentials.sh

echo "🔑 Gate 0.5: Credential Pre-Check"

# Check required environment variables
REQUIRED_VARS=(
  "SIGN_ID"           # Code signing identity
  "NOTARY_PROFILE"    # Apple notarization profile
  "GITHUB_TOKEN"      # GitHub API token
  "NPM_TOKEN"         # NPM publish token (if applicable)
)

MISSING=()
for VAR in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!VAR}" ]]; then
    MISSING+=("$VAR")
  fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "❌ Missing required credentials:"
  for VAR in "${MISSING[@]}"; do
    echo "   - $VAR"
  done
  exit 1
fi

# Verify credentials work (optional but recommended)
if command -v gh &> /dev/null; then
  if ! gh auth status &>/dev/null; then
    echo "❌ GitHub CLI not authenticated"
    exit 1
  fi
fi

echo "✅ Gate 0.5: All credentials verified"
```

### Gate 5: External Verification with Timeout

**Purpose**: Handle long-running external processes with timeout protection

**Implementation**:
```bash
#!/bin/bash
# gate-5-external-verify.sh

VERSION="$1"
TIMEOUT_MINUTES=${2:-30}

echo "🔐 Gate 5: External Verification (${TIMEOUT_MINUTES}min timeout)"

# Start notarization/external process with timeout
timeout $((TIMEOUT_MINUTES * 60)) xcrun notarytool submit \
  "./out/MyApp-${VERSION}.dmg" \
  --keychain-profile "${NOTARY_PROFILE}" \
  --wait

EXIT_CODE=$?

if [[ $EXIT_CODE -eq 124 ]]; then
  echo "⏰ TIMEOUT: Notarization exceeded ${TIMEOUT_MINUTES} minutes"
  echo ""
  echo "Recovery options:"
  echo "1. Check submission status: xcrun notarytool history --keychain-profile '${NOTARY_PROFILE}'"
  echo "2. If accepted, manually staple: xcrun stapler staple ./out/MyApp-${VERSION}.dmg"
  echo "3. Retry from Gate 5 if needed"
  exit 124
elif [[ $EXIT_CODE -ne 0 ]]; then
  echo "❌ Notarization failed with code: $EXIT_CODE"
  exit $EXIT_CODE
fi

echo "✅ Gate 5: External verification passed"
```

---

## 3. Branch Governance Enforcement

### Dual-Layer Protection Pattern

**Layer 1: Wrapper Script**
```bash
#!/bin/bash
# release.sh (wrapper)

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
RELEASE_TYPE="$1"  # "beta" or "stable"

# Enforce branch requirements
if [[ "$RELEASE_TYPE" == "beta" ]]; then
  if [[ "$CURRENT_BRANCH" != "beta" ]]; then
    echo "❌ ERROR: Beta releases must be from 'beta' branch!"
    echo "   Current branch: $CURRENT_BRANCH"
    echo "   Run: git checkout beta"
    exit 2
  fi
else
  if [[ "$CURRENT_BRANCH" != "main" && "$CURRENT_BRANCH" != "master" ]]; then
    echo "❌ ERROR: Stable releases must be from 'main' or 'master' branch!"
    echo "   Current branch: $CURRENT_BRANCH"
    exit 2
  fi
fi

# Call core pipeline
./scripts/release-pipeline.sh "$VERSION" "$RELEASE_TYPE"
```

**Layer 2: Core Pipeline**
```bash
#!/bin/bash
# release-pipeline.sh (core)

# ALSO enforce branch requirements (cannot be bypassed)
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
RELEASE_TYPE="$2"

if [[ "$RELEASE_TYPE" == "beta" ]]; then
  if [[ "$CURRENT_BRANCH" != "beta" ]]; then
    echo "❌ BRANCH VIOLATION: Beta releases MUST be from 'beta' branch!"
    exit 2
  fi
fi
```

**Layer 3: CI/CD Enforcement (GitHub Actions)**
```yaml
# .github/workflows/release-branch-guard.yml
name: Release Branch Guard

on:
  release:
    types: [created]

jobs:
  verify-branch:
    runs-on: ubuntu-latest
    steps:
      - name: Verify release branch
        run: |
          TAG="${{ github.event.release.tag_name }}"
          BRANCH="${{ github.event.release.target_commitish }}"

          if [[ "$TAG" == *"-beta"* ]]; then
            EXPECTED_BRANCH="beta"
          else
            EXPECTED_BRANCH="main"
          fi

          if [[ "$BRANCH" != "$EXPECTED_BRANCH" ]]; then
            echo "❌ Branch violation!"
            echo "   Tag: $TAG"
            echo "   Branch: $BRANCH"
            echo "   Expected: $EXPECTED_BRANCH"
            exit 1
          fi
```

---

## 4. Release Type Detection

### Automatic Channel Detection from Keywords

```bash
#!/bin/bash
# detect-release-type.sh

detect_release_type() {
  local USER_INPUT="$1"
  USER_INPUT_LOWER=$(echo "$USER_INPUT" | tr '[:upper:]' '[:lower:]')

  # Beta keywords
  if [[ "$USER_INPUT_LOWER" =~ (beta|test|pre-release|prerelease|testing|canary) ]]; then
    echo "beta"
    return
  fi

  # Default to stable
  echo "stable"
}

# Usage in release-orchestrator
RELEASE_TYPE=$(detect_release_type "$USER_REQUEST")
```

### Agent Integration

```yaml
---
name: release-orchestrator
# ...
---

# Release Type Detection

When user requests a release, automatically detect the release type from their language:

**Beta Release Indicators**:
- "release as beta"
- "test release"
- "pre-release"
- "for testing"
- "canary release"

**Stable Release Indicators** (default):
- "release v1.x.x"
- "publish to production"
- "stable release"

Route to appropriate workflow based on detection.
```

---

## 5. Pre-Release Checklist Template

### User-Facing Content Check

```yaml
# MANDATORY before ANY release:

pre_release_checklist:
  - name: "Update Release Notes"
    files:
      - "src/components/help-viewer.ts"  # Electron apps
      - "CHANGELOG.md"                    # All projects
      - "docs/releases/v*.md"             # Documentation sites
    guidelines:
      - Keep titles version-agnostic ("Latest Release", not "v1.8.xxx")
      - Include: New Features, Improvements, Bug Fixes, Known Issues
      - Dynamic content should pull from version metadata

  - name: "Verify Clean Git State"
    checks:
      - No uncommitted changes in critical files
      - No version lock files from previous releases
      - Clean working directory

  - name: "Verify Credentials"
    environment:
      - SIGN_ID (code signing)
      - NOTARY_PROFILE (Apple notarization)
      - GITHUB_TOKEN (releases)
      - NPM_TOKEN (npm publish)
```

---

## 6. Homebrew/Package Registry Patterns

### Dual-Cask Pattern (Homebrew)

```ruby
# Casks/myapp.rb (stable)
cask "myapp" do
  version "1.8.540"
  sha256 "abc123..."

  url "https://github.com/org/myapp/releases/download/v#{version}/MyApp-#{version}.dmg"
  name "MyApp"
  homepage "https://myapp.example.com"

  conflicts_with cask: "myapp-beta"

  app "MyApp.app"
end

# Casks/myapp-beta.rb (beta channel)
cask "myapp-beta" do
  version "1.8.692-beta"
  sha256 "def456..."

  url "https://github.com/org/myapp/releases/download/v#{version}/MyApp-#{version}.dmg"
  name "MyApp Beta"
  homepage "https://myapp.example.com"

  conflicts_with cask: "myapp"  # Cannot install both

  app "MyApp.app"
end
```

### NPM Package Patterns

```json
// package.json for beta
{
  "name": "@org/mypackage",
  "version": "1.8.692-beta.1",
  "publishConfig": {
    "tag": "beta"
  }
}
```

```bash
# Publish to beta tag
npm publish --tag beta

# Publish to stable (default latest tag)
npm publish
```

---

## 7. Release Orchestrator Agent Enhancement

### Universal Release Orchestrator Template

```yaml
---
name: release-orchestrator
version: 2.0.0
description: >
  Universal release pipeline coordinator with quality gates.
  Adapts to project type: Electron, NPM, Homebrew, Docker, etc.
tools: [Read, Write, Edit, Bash]
color: purple
sdk_features: [subagents, sessions, cost_tracking]
---

# Universal Release Orchestrator

## Project Detection

On invocation, detect project type from:
- `package.json` → Node.js/NPM project
- `Cargo.toml` → Rust project
- `forge.config.ts` → Electron project
- `Dockerfile` → Docker project
- `setup.py` / `pyproject.toml` → Python project

## Gate Configuration by Project Type

### Electron/Desktop Apps
- Gate 0.0: Kill stuck notarytool processes
- Gate 3: Electron Forge build
- Gate 5: Apple notarization with 30-min timeout
- Gate 9: Homebrew cask update

### NPM Packages
- Gate 0.0: Kill stuck npm processes
- Gate 3: npm run build
- Gate 5: npm publish (with --dry-run verification)
- Gate 9: npm tag management

### Docker Images
- Gate 0.0: Clean Docker build cache
- Gate 3: docker build
- Gate 5: docker push to registry
- Gate 9: Update Kubernetes manifests

## Coordination Patterns

Coordinate with specialist agents:
- `@macos-signing-expert`: Signing/notarization issues
- `@homebrew-publisher`: Homebrew cask updates
- `@npm-publisher`: NPM package publishing
- `@docker-advanced-specialist`: Docker builds
- `@documentation-expert`: Timeout troubleshooting
```

---

## 8. Adoption Checklist

### For New Projects

1. **Copy Gate Scripts**
   ```bash
   cp -r /path/to/claude-pattern/.claude/docs/release-gates/ ./scripts/release/
   ```

2. **Configure Branch Governance**
   - Create `beta` branch from `main`
   - Add branch protection rules
   - Add GitHub Actions workflow

3. **Set Up Credentials**
   ```bash
   # Environment variables
   export SIGN_ID="Developer ID Application: Your Company"
   export GITHUB_TOKEN="ghp_..."
   # etc.
   ```

4. **Customize Gate Implementations**
   - Modify Gate 3 for your build system
   - Modify Gate 5 for your verification needs
   - Modify Gate 9 for your distribution method

5. **Update Release Orchestrator**
   - Add project-specific patterns
   - Configure agent coordination
   - Test end-to-end workflow

### For Existing Projects

1. **Audit Current Release Process**
   - Identify manual steps
   - Map to gate equivalents
   - Note pain points

2. **Implement Incrementally**
   - Start with Gate 0.0 (cleanup)
   - Add Gate 0.5 (credential check)
   - Add timeout protection (Gate 5)
   - Automate distribution (Gates 8-9)

3. **Add Branch Governance**
   - Create beta channel if needed
   - Implement dual-layer enforcement
   - Add CI/CD verification

---

## 9. Troubleshooting Patterns

### Timeout Recovery

```markdown
## When Gate 5 times out after 30 minutes:

1. **Check submission status**:
   ```bash
   xcrun notarytool history --keychain-profile "$NOTARY_PROFILE"
   ```

2. **If status is "Accepted"**:
   - Manually staple: `xcrun stapler staple ./path/to/app.dmg`
   - Continue from Gate 6

3. **If status is "In Progress"**:
   - Wait and check again in 15 minutes
   - Or retry Gate 5 (will create new submission)

4. **If status is "Invalid"**:
   - Check detailed log: `xcrun notarytool log <submission_id>`
   - Fix issues and restart from Gate 1
```

### Branch Violation Recovery

```markdown
## When release fails due to branch violation:

1. **Identify correct branch**:
   - Beta release → `beta` branch
   - Stable release → `main` or `master` branch

2. **Switch branches**:
   ```bash
   git checkout beta  # for beta releases
   git checkout main  # for stable releases
   ```

3. **Ensure branch is up to date**:
   ```bash
   git pull origin <branch>
   ```

4. **Retry release**:
   ```bash
   ./scripts/release.sh [version] [--beta]
   ```
```

---

## 10. Success Metrics

### Gate Health Indicators

| Metric | Target | Action if Below |
|--------|--------|-----------------|
| Gate 0.0 success rate | 100% | Check for new stuck process types |
| Gate 3 build time | <5 min | Optimize build, check caching |
| Gate 5 timeout rate | <5% | Increase timeout, check Apple status |
| Gate 5 avg duration | <15 min | Normal Apple performance |
| Overall pipeline success | >95% | Audit failed gates, improve recovery |

### Release Velocity

| Metric | Typical Value | Notes |
|--------|---------------|-------|
| Time to release (stable) | 20-25 min | Includes all gates |
| Time to release (beta) | 20-25 min | Same pipeline |
| Retry rate | <10% | Should be rare with pre-checks |
| Manual intervention | <5% | Goal is full automation |

---

## Sources

- Hive Consensus Release Implementation (v1.8.750+)
- HOW_TO_RELEASE.md
- RELEASE_GOVERNANCE.md
- RELEASE_QUALITY_GATES.md
- RELEASE_TROUBLESHOOTING.md
- release-orchestrator agent (v1.7.0)
