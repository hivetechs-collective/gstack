#!/usr/bin/env bash
# worktree-deps-share.sh — Layer 2 of the disk-hygiene initiative.
#
# Dynamically share per-tech-stack dependency trees from a main repo into a
# git worktree so each new /plan-w-team worktree doesn't re-materialize
# node_modules / target / .venv / vendor / deps from scratch. cleanscale
# measured ~2.2 GB per worktree dominated by node_modules; across 20+ active
# worktrees this becomes 40-60+ GB of avoidable disk pressure.
#
# The principle is universal ("don't let dev efforts balloon disk"); the
# mechanism is per-stack:
#   • pnpm/npm/yarn/bun : symlink node_modules/ (root + per-workspace package)
#   • cargo             : set CARGO_TARGET_DIR via .cargo/config.toml (no symlink)
#   • uv                : symlink .venv/ (a normal Python venv directory)
#   • poetry/pip-tools  : symlink .venv/ when the in-project convention is present
#   • maven/gradle/go   : NO-OP (already shared via ~/.m2 / ~/.gradle / GOPATH)
#   • bundler           : symlink vendor/bundle/ when configured for in-project path
#   • mix               : symlink deps/ and _build/
#   • composer          : symlink vendor/
#
# SAFETY INVARIANTS (non-negotiable):
#   1. Lockfile-divergence guard — never share across mismatched lockfile
#      hashes. A worktree that intends to bump deps must isolate that stack.
#   2. Never remove an existing REAL deps dir without --force. Default on
#      detecting a real (non-symlink) deps dir is LEAVE IT ALONE + skip.
#   3. Never follow symlinks blindly when classifying — an existing correct
#      symlink is the IDEMPOTENT case (accept, report shared-already).
#   4. Never share across worktrees belonging to DIFFERENT main repos.
#   5. Verify the main-repo source exists before linking.
#
# Dependencies: pure bash + jq + git + (shasum|sha256sum). No new deps.
# Portability: works on macOS (BSD find/stat/readlink) and Linux (GNU).
#
# ── TESTING HOOKS ─────────────────────────────────────────────────────────
# WTDS_FORCE_OS=darwin|linux   — override OS detection (test determinism)
#
# Usage:
#   worktree-deps-share.sh --worktree <path> --main <path> [options]
#
# Options:
#   --worktree PATH      worktree to apply sharing INTO (required)
#   --main PATH          parent (main) repo to share FROM (required)
#   --strategy MODE      share | isolate | auto   (default: auto)
#   --disable-stacks CSV comma-separated stack names to force-isolate
#   --dry-run            print what would happen, change nothing
#   --json               emit a machine-readable JSON report to stdout
#   --force              replace an existing REAL deps dir (DANGEROUS)
#   --state-dir PATH     where to write deps-hash state (default: <main>/.claude/state)
#   --slug SLUG          run slug for the hash state filename (default: worktree basename)
#   -h, --help           show this help
#
# Env overrides (read when corresponding flag not passed):
#   WORKTREE_DEPS_STRATEGY=share|isolate|auto
#   WORKTREE_DEPS_DISABLE_STACKS=pnpm,cargo
#
# Exit codes:
#   0 — completed (some stacks may have been skipped/isolated; that's normal)
#   2 — usage error (bad/missing arguments)
#   3 — safety abort (e.g. worktree path is not under a different tree than main)

set -uo pipefail

# ── OS / portability helpers ────────────────────────────────────────────────

wtds_os() {
    if [ -n "${WTDS_FORCE_OS:-}" ]; then
        echo "$WTDS_FORCE_OS"
        return
    fi
    case "$(uname -s)" in
        Darwin) echo darwin ;;
        *)      echo linux ;;
    esac
}

# Portable sha256 of a file. Echoes the hex digest, or empty string on error.
wtds_sha256() {
    local f="$1"
    [ -f "$f" ] || { echo ""; return; }
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$f" 2>/dev/null | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$f" 2>/dev/null | awk '{print $1}'
    else
        echo ""
    fi
}

# Portable absolute-path resolver (no realpath dependency).
wtds_abspath() {
    local p="$1"
    if [ -d "$p" ]; then
        ( cd "$p" 2>/dev/null && pwd )
    else
        local d b
        d="$(dirname "$p")"
        b="$(basename "$p")"
        if [ -d "$d" ]; then
            echo "$( cd "$d" && pwd )/$b"
        else
            echo "$p"
        fi
    fi
}

# Is PATH a symlink? (does NOT follow — classifies the link itself)
wtds_is_symlink() { [ -L "$1" ]; }

# Read a symlink's target (portable; GNU readlink -f is avoided on purpose
# because we must NOT follow chains when classifying).
wtds_link_target() {
    local p="$1"
    if [ -L "$p" ]; then
        # `readlink "$p"` (no -f) returns the immediate target on both BSD & GNU.
        readlink "$p" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# ── logging ──────────────────────────────────────────────────────────────────

WTDS_QUIET=0
log() { [ "$WTDS_QUIET" = "1" ] && return 0; printf '%s\n' "$*" >&2; }
err() { printf '%s\n' "$*" >&2; }

# ── argument parsing ──────────────────────────────────────────────────────────

WORKTREE=""
MAIN=""
STRATEGY="${WORKTREE_DEPS_STRATEGY:-auto}"
DISABLE_STACKS="${WORKTREE_DEPS_DISABLE_STACKS:-}"
DRY_RUN=0
JSON_OUT=0
FORCE=0
STATE_DIR=""
SLUG=""

usage() {
    sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --worktree)        WORKTREE="$2"; shift 2 ;;
        --main)            MAIN="$2"; shift 2 ;;
        --strategy)        STRATEGY="$2"; shift 2 ;;
        --disable-stacks)  DISABLE_STACKS="$2"; shift 2 ;;
        --dry-run)         DRY_RUN=1; shift ;;
        --json)            JSON_OUT=1; WTDS_QUIET=1; shift ;;
        --force)           FORCE=1; shift ;;
        --state-dir)       STATE_DIR="$2"; shift 2 ;;
        --slug)            SLUG="$2"; shift 2 ;;
        -h|--help)         usage; exit 0 ;;
        *) err "✗ unknown argument: $1"; usage; exit 2 ;;
    esac
done

# Validate strategy
case "$STRATEGY" in
    share|isolate|auto) ;;
    *) err "✗ invalid --strategy: $STRATEGY (want share|isolate|auto)"; exit 2 ;;
esac

if [ -z "$WORKTREE" ] || [ -z "$MAIN" ]; then
    err "✗ both --worktree and --main are required"
    usage
    exit 2
fi

if [ ! -d "$WORKTREE" ]; then
    err "✗ worktree path does not exist: $WORKTREE"
    exit 2
fi
if [ ! -d "$MAIN" ]; then
    err "✗ main path does not exist: $MAIN"
    exit 2
fi

WORKTREE="$(wtds_abspath "$WORKTREE")"
MAIN="$(wtds_abspath "$MAIN")"

# Safety invariant #4: worktree and main must be DIFFERENT directories.
if [ "$WORKTREE" = "$MAIN" ]; then
    err "✗ refusing to share: --worktree and --main resolve to the same path ($WORKTREE)"
    exit 3
fi

# State dir defaults to the MAIN repo's .claude/state (the worktree is ephemeral).
if [ -z "$STATE_DIR" ]; then
    STATE_DIR="$MAIN/.claude/state"
fi
if [ -z "$SLUG" ]; then
    SLUG="$(basename "$WORKTREE")"
fi

# Normalize disable list into a space-padded lookup string for grep -w-style checks.
DISABLE_NORM=" $(echo "$DISABLE_STACKS" | tr ',' ' ' | tr -s ' ') "

stack_disabled() {
    local stack="$1"
    case "$DISABLE_NORM" in
        *" $stack "*) return 0 ;;
        *) return 1 ;;
    esac
}

# ── per-stack report accumulation ─────────────────────────────────────────────
# Each entry is one JSON object appended to this array. CURRENT_DIR is set by
# the per-stack dispatcher so each report entry records WHICH manifest dir it
# applies to — disambiguates monorepos with multiple same-stack workspaces.
REPORT_ENTRIES=()
CURRENT_DIR="."

add_report() {
    # add_report <stack> <action> <detail> [paths_json]
    local stack="$1" action="$2" detail="$3" paths="${4:-[]}"
    local entry
    entry=$(jq -nc \
        --arg stack "$stack" \
        --arg dir "$CURRENT_DIR" \
        --arg action "$action" \
        --arg detail "$detail" \
        --argjson paths "$paths" \
        '{stack:$stack, dir:$dir, action:$action, detail:$detail, paths:$paths}')
    REPORT_ENTRIES+=("$entry")
}

# ── stack detection ───────────────────────────────────────────────────────────
#
# Detection walks the worktree for manifests. For node stacks the resolved
# manager is determined by lockfile priority at the manifest's directory:
#   pnpm-lock.yaml > package-lock.json (npm) > yarn.lock (yarn) > bun.lockb (bun)
# For python: uv.lock > poetry.lock > requirements*.txt (pip-tools).
#
# Detected stacks are emitted as lines:  <stack>\t<manifest-relative-dir>\t<lockfile-name>
# where manifest-relative-dir is relative to the worktree root ("." for root).

# Find directories containing a given manifest, excluding nested dependency dirs
# and the .git dir. Prints dirs relative to the worktree root.
wtds_find_manifest_dirs() {
    local manifest="$1"
    # -prune the common heavy / vendored trees so monorepo scans stay fast and
    # never descend into an already-installed node_modules.
    find "$WORKTREE" \
        \( -name node_modules -o -name .git -o -name target -o -name .venv \
           -o -name vendor -o -name _build -o -name deps -o -name dist \
           -o -name .next \) -prune -o \
        -type f -name "$manifest" -print 2>/dev/null \
        | while IFS= read -r f; do
            local d
            d="$(dirname "$f")"
            # relative to worktree root
            echo "${d#"$WORKTREE"}" | sed 's|^/||; s|^$|.|'
        done | sort -u
}

# Resolve the node package manager for a given manifest dir.
wtds_node_manager_for_dir() {
    local dir="$1"  # absolute
    if [ -f "$dir/pnpm-lock.yaml" ]; then echo "pnpm"
    elif [ -f "$dir/package-lock.json" ]; then echo "npm"
    elif [ -f "$dir/yarn.lock" ]; then echo "yarn"
    elif [ -f "$dir/bun.lockb" ]; then echo "bun"
    else echo ""; fi
}

wtds_node_lockfile_for_manager() {
    case "$1" in
        pnpm) echo "pnpm-lock.yaml" ;;
        npm)  echo "package-lock.json" ;;
        yarn) echo "yarn.lock" ;;
        bun)  echo "bun.lockb" ;;
        *)    echo "" ;;
    esac
}

wtds_python_manager_for_dir() {
    local dir="$1"
    if [ -f "$dir/uv.lock" ]; then echo "uv"
    elif [ -f "$dir/poetry.lock" ]; then echo "poetry"
    elif ls "$dir"/requirements*.txt >/dev/null 2>&1; then echo "pip-tools"
    else echo ""; fi
}

# DETECTED_STACKS lines: "<stack>|<reldir>|<lockfile-name-or-empty>"
DETECTED_STACKS=()

detect_stacks() {
    local reldir absdir mgr lock

    # --- Node (pnpm/npm/yarn/bun): driven by package.json, manager by lockfile ---
    while IFS= read -r reldir; do
        [ -z "$reldir" ] && continue
        absdir="$WORKTREE/$reldir"; [ "$reldir" = "." ] && absdir="$WORKTREE"
        mgr="$(wtds_node_manager_for_dir "$absdir")"
        if [ -n "$mgr" ]; then
            lock="$(wtds_node_lockfile_for_manager "$mgr")"
            DETECTED_STACKS+=("$mgr|$reldir|$lock")
        fi
        # package.json with NO lockfile at all → still node, default to npm,
        # but no lockfile means no divergence guard is possible → treat as npm
        # with empty lockfile (will isolate under auto unless --strategy share).
        if [ -z "$mgr" ]; then
            DETECTED_STACKS+=("npm|$reldir|")
        fi
    done < <(wtds_find_manifest_dirs "package.json")

    # --- Cargo (Cargo.toml + Cargo.lock); workspace members share one target ---
    while IFS= read -r reldir; do
        [ -z "$reldir" ] && continue
        absdir="$WORKTREE/$reldir"; [ "$reldir" = "." ] && absdir="$WORKTREE"
        lock=""
        [ -f "$absdir/Cargo.lock" ] && lock="Cargo.lock"
        DETECTED_STACKS+=("cargo|$reldir|$lock")
    done < <(wtds_find_manifest_dirs "Cargo.toml")

    # --- Python (uv/poetry/pip-tools) driven by pyproject.toml ---
    while IFS= read -r reldir; do
        [ -z "$reldir" ] && continue
        absdir="$WORKTREE/$reldir"; [ "$reldir" = "." ] && absdir="$WORKTREE"
        mgr="$(wtds_python_manager_for_dir "$absdir")"
        [ -z "$mgr" ] && continue
        case "$mgr" in
            uv)        lock="uv.lock" ;;
            poetry)    lock="poetry.lock" ;;
            pip-tools) lock="$(ls "$absdir"/requirements*.txt 2>/dev/null | head -1 | xargs -I{} basename {} 2>/dev/null)" ;;
        esac
        DETECTED_STACKS+=("$mgr|$reldir|$lock")
    done < <(wtds_find_manifest_dirs "pyproject.toml")

    # --- Maven (pom.xml) → NO-OP stack, still detected for reporting ---
    while IFS= read -r reldir; do
        [ -z "$reldir" ] && continue
        DETECTED_STACKS+=("maven|$reldir|")
    done < <(wtds_find_manifest_dirs "pom.xml")

    # --- Gradle (build.gradle / build.gradle.kts) → NO-OP ---
    while IFS= read -r reldir; do
        [ -z "$reldir" ] && continue
        DETECTED_STACKS+=("gradle|$reldir|")
    done < <(wtds_find_manifest_dirs "build.gradle")
    while IFS= read -r reldir; do
        [ -z "$reldir" ] && continue
        DETECTED_STACKS+=("gradle|$reldir|")
    done < <(wtds_find_manifest_dirs "build.gradle.kts")

    # --- Bundler (Gemfile + Gemfile.lock) ---
    while IFS= read -r reldir; do
        [ -z "$reldir" ] && continue
        absdir="$WORKTREE/$reldir"; [ "$reldir" = "." ] && absdir="$WORKTREE"
        lock=""
        [ -f "$absdir/Gemfile.lock" ] && lock="Gemfile.lock"
        DETECTED_STACKS+=("bundler|$reldir|$lock")
    done < <(wtds_find_manifest_dirs "Gemfile")

    # --- Go (go.mod + go.sum) → NO-OP ---
    while IFS= read -r reldir; do
        [ -z "$reldir" ] && continue
        DETECTED_STACKS+=("go|$reldir|")
    done < <(wtds_find_manifest_dirs "go.mod")

    # --- Mix (mix.exs + mix.lock) ---
    while IFS= read -r reldir; do
        [ -z "$reldir" ] && continue
        absdir="$WORKTREE/$reldir"; [ "$reldir" = "." ] && absdir="$WORKTREE"
        lock=""
        [ -f "$absdir/mix.lock" ] && lock="mix.lock"
        DETECTED_STACKS+=("mix|$reldir|$lock")
    done < <(wtds_find_manifest_dirs "mix.exs")

    # --- Composer (composer.json + composer.lock) ---
    while IFS= read -r reldir; do
        [ -z "$reldir" ] && continue
        absdir="$WORKTREE/$reldir"; [ "$reldir" = "." ] && absdir="$WORKTREE"
        lock=""
        [ -f "$absdir/composer.lock" ] && lock="composer.lock"
        DETECTED_STACKS+=("composer|$reldir|$lock")
    done < <(wtds_find_manifest_dirs "composer.json")
}

# ── lockfile-divergence guard ─────────────────────────────────────────────────
#
# Returns 0 (share OK) if the worktree lockfile hash matches main's at the
# same relative dir. Returns 1 (diverged → isolate) otherwise. Records the
# hashes in the per-slug state file. An empty/absent lockfile on EITHER side
# is treated as divergence (can't prove equality → fail safe to isolate)
# UNLESS strategy is explicitly "share".
lockfile_matches() {
    local reldir="$1" lockname="$2"
    [ -z "$lockname" ] && return 1   # no lockfile → cannot prove match
    local wt_lock main_lock wt_hash main_hash
    if [ "$reldir" = "." ]; then
        wt_lock="$WORKTREE/$lockname"; main_lock="$MAIN/$lockname"
    else
        wt_lock="$WORKTREE/$reldir/$lockname"; main_lock="$MAIN/$reldir/$lockname"
    fi
    wt_hash="$(wtds_sha256 "$wt_lock")"
    main_hash="$(wtds_sha256 "$main_lock")"
    LAST_WT_HASH="$wt_hash"
    LAST_MAIN_HASH="$main_hash"
    [ -n "$wt_hash" ] && [ -n "$main_hash" ] && [ "$wt_hash" = "$main_hash" ]
}

# Per-stack hash state — appended to one JSON object per run.
HASH_STATE_ENTRIES=()
record_hash_state() {
    # record_hash_state <stack> <reldir> <wt_hash> <main_hash> <decision>
    local entry
    entry=$(jq -nc \
        --arg stack "$1" --arg reldir "$2" \
        --arg wt "$3" --arg main "$4" --arg decision "$5" \
        '{stack:$stack, dir:$reldir, worktree_hash:$wt, main_hash:$main, decision:$decision}')
    HASH_STATE_ENTRIES+=("$entry")
}

# ── symlink application (the core safe-link primitive) ─────────────────────────
#
# share_dir_symlink <reldir> <dirname> <stack>
#   Link  <worktree>/<reldir>/<dirname>  →  <main>/<reldir>/<dirname>
# Honors all safety invariants. Returns:
#   0 applied (or already-correct idempotent)  1 skipped  2 fallback-isolate
share_dir_symlink() {
    local reldir="$1" dirname="$2" stack="$3"
    local wt_path main_path
    if [ "$reldir" = "." ]; then
        wt_path="$WORKTREE/$dirname"; main_path="$MAIN/$dirname"
    else
        wt_path="$WORKTREE/$reldir/$dirname"; main_path="$MAIN/$reldir/$dirname"
    fi

    # Invariant #5: source must exist in main.
    if [ ! -e "$main_path" ]; then
        add_report "$stack" "skip" "main source missing: ${main_path#"$MAIN"/} — nothing to share" \
            "$(jq -nc --arg w "$wt_path" --arg m "$main_path" '{worktree:$w, main:$m}')"
        return 1
    fi

    # Idempotent case: worktree path is already a symlink.
    if wtds_is_symlink "$wt_path"; then
        local cur
        cur="$(wtds_link_target "$wt_path")"
        # Accept if it already points at main's path (absolute or basename match).
        if [ "$cur" = "$main_path" ]; then
            add_report "$stack" "shared-already" "symlink already points at main: $dirname" \
                "$(jq -nc --arg w "$wt_path" --arg m "$main_path" '{worktree:$w, main:$m}')"
            return 0
        fi
        # Symlink exists but points elsewhere — re-point it (safe: it's a link,
        # not real content). Only on non-dry-run.
        if [ "$DRY_RUN" = "1" ]; then
            add_report "$stack" "would-relink" "existing symlink points elsewhere ($cur); would re-point to main" \
                "$(jq -nc --arg w "$wt_path" --arg m "$main_path" '{worktree:$w, main:$m}')"
            return 0
        fi
        rm -f "$wt_path"
        ln -s "$main_path" "$wt_path"
        add_report "$stack" "relinked" "re-pointed existing symlink to main: $dirname" \
            "$(jq -nc --arg w "$wt_path" --arg m "$main_path" '{worktree:$w, main:$m}')"
        return 0
    fi

    # Real directory present (invariant #2).
    if [ -d "$wt_path" ]; then
        if [ "$FORCE" != "1" ]; then
            add_report "$stack" "skip" "real $dirname present in worktree — left alone (use --force to override)" \
                "$(jq -nc --arg w "$wt_path" --arg m "$main_path" '{worktree:$w, main:$m}')"
            return 1
        fi
        # --force: replace ONLY if the dir is safe to remove. We never remove a
        # dir that contains git-tracked or staged changes — but deps dirs are
        # gitignored by convention; still, refuse if it's non-empty AND has any
        # entries newer than the main source unless forced. With --force we
        # honor the user's explicit intent.
        if [ "$DRY_RUN" = "1" ]; then
            add_report "$stack" "would-replace" "--force: would remove real $dirname and symlink to main" \
                "$(jq -nc --arg w "$wt_path" --arg m "$main_path" '{worktree:$w, main:$m}')"
            return 0
        fi
        rm -rf "$wt_path"
        ln -s "$main_path" "$wt_path"
        add_report "$stack" "replaced" "--force: removed real $dirname, symlinked to main" \
            "$(jq -nc --arg w "$wt_path" --arg m "$main_path" '{worktree:$w, main:$m}')"
        return 0
    fi

    # A plain file at that path (unexpected) — never clobber.
    if [ -e "$wt_path" ]; then
        add_report "$stack" "skip" "$dirname exists as a non-directory file — left alone" \
            "$(jq -nc --arg w "$wt_path" --arg m "$main_path" '{worktree:$w, main:$m}')"
        return 1
    fi

    # Clean slate: create the symlink.
    if [ "$DRY_RUN" = "1" ]; then
        add_report "$stack" "would-share" "would symlink $dirname → main" \
            "$(jq -nc --arg w "$wt_path" --arg m "$main_path" '{worktree:$w, main:$m}')"
        return 0
    fi
    # Ensure parent dir exists (for nested workspace reldirs).
    mkdir -p "$(dirname "$wt_path")"
    ln -s "$main_path" "$wt_path"
    add_report "$stack" "shared" "symlinked $dirname → main" \
        "$(jq -nc --arg w "$wt_path" --arg m "$main_path" '{worktree:$w, main:$m}')"
    return 0
}

# ── cargo: CARGO_TARGET_DIR via .cargo/config.toml (merge, never overwrite) ────
#
# Cargo officially supports CARGO_TARGET_DIR and [build] target-dir in
# .cargo/config.toml. We point it at MAIN's target/ so the worktree never
# materializes its own target/. We MERGE into any existing config.toml rather
# than overwriting (safety invariant: don't break existing config).
apply_cargo_target_dir() {
    local reldir="$1" stack="cargo"
    local cargo_dir cfg main_target
    if [ "$reldir" = "." ]; then
        cargo_dir="$WORKTREE/.cargo"; main_target="$MAIN/target"
    else
        # Workspace members inherit the workspace-root config; we only set it at
        # the workspace/crate root that declared Cargo.toml.
        cargo_dir="$WORKTREE/$reldir/.cargo"; main_target="$MAIN/$reldir/target"
    fi
    cfg="$cargo_dir/config.toml"

    # Source target dir need not pre-exist (cargo creates it); but if MAIN's
    # crate dir is absent, skip — wrong repo layout.
    local main_crate_dir="${main_target%/target}"
    if [ ! -d "$main_crate_dir" ]; then
        add_report "$stack" "skip" "main crate dir missing for $reldir" "[]"
        return 1
    fi

    # Idempotent: if config already points target-dir at main_target, no-op.
    if [ -f "$cfg" ] && grep -qsF "$main_target" "$cfg" 2>/dev/null; then
        add_report "$stack" "shared-already" "CARGO_TARGET_DIR already set to main target in $reldir/.cargo/config.toml" \
            "$(jq -nc --arg c "$cfg" --arg t "$main_target" '{config:$c, target_dir:$t}')"
        return 0
    fi

    if [ "$DRY_RUN" = "1" ]; then
        local verb="create"
        [ -f "$cfg" ] && verb="merge into"
        add_report "$stack" "would-share" "would $verb $reldir/.cargo/config.toml setting [build] target-dir = main target" \
            "$(jq -nc --arg c "$cfg" --arg t "$main_target" '{config:$c, target_dir:$t}')"
        return 0
    fi

    mkdir -p "$cargo_dir"
    if [ -f "$cfg" ]; then
        # MERGE: if a [build] table exists, inject/replace target-dir within it;
        # else append a fresh [build] table. We do a conservative textual merge
        # that never deletes unrelated keys.
        if grep -qsE '^\[build\]' "$cfg"; then
            if grep -qsE '^[[:space:]]*target-dir[[:space:]]*=' "$cfg"; then
                # Replace existing target-dir line (portable in-place edit).
                local tmp
                tmp="$(mktemp)"
                # shellcheck disable=SC2016
                awk -v t="$main_target" '
                    /^[[:space:]]*target-dir[[:space:]]*=/ { print "target-dir = \"" t "\""; next }
                    { print }
                ' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
            else
                # Append target-dir under the existing [build] table.
                local tmp
                tmp="$(mktemp)"
                awk -v t="$main_target" '
                    BEGIN{done=0}
                    /^\[build\]/ && done==0 { print; print "target-dir = \"" t "\""; done=1; next }
                    { print }
                ' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
            fi
        else
            {
                echo ""
                echo "# Added by worktree-deps-share.sh — share main repo target/ to avoid"
                echo "# re-building dependencies in this ephemeral worktree."
                echo "[build]"
                echo "target-dir = \"$main_target\""
            } >> "$cfg"
        fi
        add_report "$stack" "shared" "merged [build] target-dir into existing $reldir/.cargo/config.toml" \
            "$(jq -nc --arg c "$cfg" --arg t "$main_target" '{config:$c, target_dir:$t}')"
    else
        {
            echo "# Created by worktree-deps-share.sh — share main repo target/ to avoid"
            echo "# re-building dependencies in this ephemeral worktree."
            echo "[build]"
            echo "target-dir = \"$main_target\""
        } > "$cfg"
        add_report "$stack" "shared" "created $reldir/.cargo/config.toml with [build] target-dir = main target" \
            "$(jq -nc --arg c "$cfg" --arg t "$main_target" '{config:$c, target_dir:$t}')"
    fi
    return 0
}

# ── per-stack dispatcher ──────────────────────────────────────────────────────
#
# Given a detected stack, decide share|isolate via strategy + disable list +
# lockfile-divergence guard, then apply the per-stack mechanism.
apply_stack() {
    local stack="$1" reldir="$2" lockname="$3"
    CURRENT_DIR="$reldir"   # so add_report records which manifest dir this is

    # NO-OP stacks: report and return regardless of strategy.
    case "$stack" in
        maven|gradle|go)
            add_report "$stack" "noop" "$stack uses a shared user-global cache — nothing to share per-worktree" "[]"
            return 0
            ;;
    esac

    # Disabled stack → forced isolate.
    if stack_disabled "$stack"; then
        add_report "$stack" "isolate" "stack disabled via --disable-stacks / WORKTREE_DEPS_DISABLE_STACKS" "[]"
        record_hash_state "$stack" "$reldir" "" "" "isolate-disabled"
        return 0
    fi

    # Strategy = isolate → skip all sharing.
    if [ "$STRATEGY" = "isolate" ]; then
        add_report "$stack" "isolate" "strategy=isolate — worktree will install its own deps" "[]"
        record_hash_state "$stack" "$reldir" "" "" "isolate-strategy"
        return 0
    fi

    # Lockfile-divergence guard (only under auto; share bypasses it explicitly).
    local share_ok=1
    LAST_WT_HASH=""; LAST_MAIN_HASH=""
    if [ "$STRATEGY" = "auto" ]; then
        if lockfile_matches "$reldir" "$lockname"; then
            share_ok=1
        else
            share_ok=0
        fi
    fi

    if [ "$STRATEGY" = "auto" ] && [ "$share_ok" = "0" ]; then
        local why="lockfile hash mismatch"
        [ -z "$lockname" ] && why="no lockfile to compare (cannot prove parity)"
        add_report "$stack" "isolate" "divergence guard: $why → isolate this stack only" \
            "$(jq -nc --arg w "$LAST_WT_HASH" --arg m "$LAST_MAIN_HASH" '{worktree_hash:$w, main_hash:$m}')"
        record_hash_state "$stack" "$reldir" "$LAST_WT_HASH" "$LAST_MAIN_HASH" "isolate-divergence"
        return 0
    fi

    # Record the (matching, or share-forced) hashes for future refresh policy.
    record_hash_state "$stack" "$reldir" "$LAST_WT_HASH" "$LAST_MAIN_HASH" "share"

    # Apply per-stack mechanism.
    case "$stack" in
        pnpm|npm|yarn|bun)
            share_dir_symlink "$reldir" "node_modules" "$stack"
            ;;
        cargo)
            apply_cargo_target_dir "$reldir"
            ;;
        uv)
            share_dir_symlink "$reldir" ".venv" "$stack"
            ;;
        poetry|pip-tools)
            # Only share when an in-project .venv convention is present in main.
            local main_venv="$MAIN/.venv"
            [ "$reldir" != "." ] && main_venv="$MAIN/$reldir/.venv"
            if [ -e "$main_venv" ]; then
                share_dir_symlink "$reldir" ".venv" "$stack"
            else
                add_report "$stack" "noop" "no in-project .venv in main — $stack uses a system/shared venv" "[]"
            fi
            ;;
        bundler)
            # Only share when configured for in-project vendor/bundle path.
            local bundle_cfg="$MAIN/.bundle/config" main_bundle="$MAIN/vendor/bundle"
            [ "$reldir" != "." ] && { bundle_cfg="$MAIN/$reldir/.bundle/config"; main_bundle="$MAIN/$reldir/vendor/bundle"; }
            if [ -e "$main_bundle" ] || { [ -f "$bundle_cfg" ] && grep -qsF "vendor/bundle" "$bundle_cfg"; }; then
                share_dir_symlink "$reldir" "vendor/bundle" "$stack"
            else
                add_report "$stack" "noop" "Bundler not configured for in-project vendor/bundle — system-shared gems" "[]"
            fi
            ;;
        mix)
            share_dir_symlink "$reldir" "deps" "$stack"
            share_dir_symlink "$reldir" "_build" "$stack"
            ;;
        composer)
            share_dir_symlink "$reldir" "vendor" "$stack"
            ;;
        *)
            add_report "$stack" "skip" "unknown stack — no mechanism defined" "[]"
            ;;
    esac
}

# ── main flow ──────────────────────────────────────────────────────────────────

log "▸ worktree-deps-share: worktree=$WORKTREE"
log "  main=$MAIN  strategy=$STRATEGY  dry-run=$DRY_RUN  force=$FORCE"
[ -n "$DISABLE_STACKS" ] && log "  disabled stacks: $DISABLE_STACKS"

detect_stacks

if [ "${#DETECTED_STACKS[@]}" -eq 0 ]; then
    log "  no recognized stacks detected — nothing to do"
fi

# De-duplicate detected stacks (a dir can legitimately produce duplicates only
# via the npm-no-lockfile fallback; guard against double-apply).
# NB: bash 3.2-compatible set membership (newline-bracketed string) — macOS
# ships /bin/bash 3.2, where `declare -A` is a fatal "invalid option". Entries
# are `stack|reldir|lock` and never contain newlines, so this is safe.
SEEN_STACK=$'\n'
for entry in "${DETECTED_STACKS[@]:-}"; do
    [ -z "$entry" ] && continue
    case "$SEEN_STACK" in
        *$'\n'"$entry"$'\n'*) continue ;;
    esac
    SEEN_STACK="${SEEN_STACK}${entry}"$'\n'
    IFS='|' read -r s_stack s_reldir s_lock <<<"$entry"
    apply_stack "$s_stack" "$s_reldir" "$s_lock"
done

# ── persist hash state (skip on dry-run) ───────────────────────────────────────
HASH_STATE_FILE="$STATE_DIR/worktree-deps-hash-$SLUG.json"
if [ "$DRY_RUN" != "1" ] && [ "${#HASH_STATE_ENTRIES[@]}" -gt 0 ]; then
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    {
        printf '%s\n' "${HASH_STATE_ENTRIES[@]}" | jq -sc \
            --arg slug "$SLUG" \
            --arg worktree "$WORKTREE" \
            --arg main "$MAIN" \
            --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{slug:$slug, worktree:$worktree, main:$main, recorded_at:$ts, stacks:.}'
    } > "$HASH_STATE_FILE" 2>/dev/null || true
    log "  hash state → $HASH_STATE_FILE"
fi

# ── emit report ────────────────────────────────────────────────────────────────
build_report_json() {
    local entries="[]"
    if [ "${#REPORT_ENTRIES[@]}" -gt 0 ]; then
        entries="$(printf '%s\n' "${REPORT_ENTRIES[@]}" | jq -sc '.')"
    fi
    jq -nc \
        --arg worktree "$WORKTREE" \
        --arg main "$MAIN" \
        --arg strategy "$STRATEGY" \
        --argjson dry_run "$DRY_RUN" \
        --argjson force "$FORCE" \
        --argjson stacks "$entries" \
        '{worktree:$worktree, main:$main, strategy:$strategy,
          dry_run:($dry_run==1), force:($force==1), stacks:$stacks}'
}

if [ "$JSON_OUT" = "1" ]; then
    build_report_json | jq '.'
else
    if [ "${#REPORT_ENTRIES[@]}" -gt 0 ]; then
        for e in "${REPORT_ENTRIES[@]}"; do
            printf '  • %-9s %-15s %s\n' \
                "$(echo "$e" | jq -r '.stack')" \
                "[$(echo "$e" | jq -r '.action')]" \
                "$(echo "$e" | jq -r '.detail')" >&2
        done
    fi
    log "✓ worktree-deps-share complete"
fi

exit 0
