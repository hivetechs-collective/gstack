#!/bin/bash
# Config Protection Hook (PreToolUse: Write|Edit)
# Blocks modifications to linter/formatter config files.
# Agents frequently weaken configs instead of fixing code.
#
# Exit codes:
#   0 = allow (not a config file)
#   2 = block (config file modification attempted)

set -e

UTILS_DIR="$(cd "$(dirname "$0")/utils" && pwd)"
source "$UTILS_DIR/hook-profile.sh"
hook_gate "pre:edit:config-protection" "standard,strict"

INPUT=$(cat)

# Extract file_path from JSON
FILE_PATH=$(echo "$INPUT" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "")

if [ -z "$FILE_PATH" ]; then
    echo "$INPUT"
    exit 0
fi

BASENAME=$(basename "$FILE_PATH")

# ---------------------------------------------------------------------------
# Shell startup files — DIRECT CHILDREN OF $HOME ONLY
# ---------------------------------------------------------------------------
# A ~/.zshrc write is the one blast radius that escapes every repo-scoped
# guardrail: damage-control.sh's zero_access/read_only arrays contain no shell
# rc file, and every other guard here is scoped to the repo.
#
# Path scoping is load-bearing, not a nicety. A basename-only match over-blocks
# legitimate in-repo .zshrc/.profile fixtures across consumer repos, which is
# exactly why this was DEFERRED rather than shipped on 2026-06-28 — see
# docs/operations/version-uplift-reports/2026-06-27-2.1.195.md:55-58 for the
# design this implements.
#
# bash 3.2 compatible (mac-mini runs /bin/bash 3.2): no associative arrays, no
# ${var,,}, no realpath. Blocks with exit 2 + stderr, per the PreToolUse
# contract — see the 1.60.0 CHANGELOG entry and hook-enforcement-contract.bats.
case "$BASENAME" in
    .zshrc|.zshenv|.zprofile|.zlogin|.zlogout|.bashrc|.bash_profile|.bash_login|.bash_logout|.profile|.inputrc)
        __cp_path="$FILE_PATH"
        # Expand a leading "~/" so "~/.zshrc" is treated as "$HOME/.zshrc".
        case "$__cp_path" in
            "~/"*) __cp_path="$HOME/${__cp_path#\~/}" ;;
        esac
        __cp_home="${HOME%/}"
        __cp_dir=$(dirname "$__cp_path")
        case "$__cp_dir" in */.) __cp_dir="${__cp_dir%/.}" ;; esac
        __cp_dir="${__cp_dir%/}"

        # Fail closed on traversal aimed into $HOME (e.g. $HOME/repo/../.zshrc):
        # dirname would report .../repo/.. and the equality test below would
        # miss it, so refuse rather than resolve it in pure bash.
        case "$__cp_path" in
            *"/../"*|*"/..")
                case "$__cp_path" in
                    "$__cp_home"/*)
                        echo "BLOCKED: refusing to write $BASENAME through a path containing '..' under \$HOME ($FILE_PATH). Shell startup files in \$HOME are protected; pass an unambiguous absolute path if this is a legitimate in-repo file. Override: CLAUDE_DISABLED_HOOKS=pre:edit:config-protection" >&2
                        exit 2
                        ;;
                esac
                ;;
        esac

        if [ "$__cp_dir" = "$__cp_home" ]; then
            echo "BLOCKED: $FILE_PATH is a shell startup file in \$HOME. Editing it changes every future shell on this machine — the one blast radius no repo-scoped guardrail covers. In-repo .zshrc/.profile files are unaffected. If this is deliberate, edit it yourself or set CLAUDE_DISABLED_HOOKS=pre:edit:config-protection" >&2
            exit 2
        fi

        # Symlink coverage: ~/.zshrc is frequently a symlink into a dotfiles
        # repo (stow/chezmoi/hand-rolled — e.g. ~/.dotfiles/zsh/.zshrc). The
        # live rc file is then reachable under a second name the direct-child
        # test above never sees: same inode, same blast radius. If any $HOME
        # rc symlink resolves to the written path, block. One readlink level
        # only (no realpath on bash 3.2) and only targets whose basename is
        # itself an rc name reach this branch — both accepted residual risk.
        # The in-repo carve-out survives: a repo fixture is never the target
        # of a $HOME rc symlink unless it IS the live rc file.
        for __cp_rc in .zshrc .zshenv .zprofile .zlogin .zlogout .bashrc .bash_profile .bash_login .bash_logout .profile .inputrc; do
            [ -L "$__cp_home/$__cp_rc" ] || continue
            __cp_tgt=$(readlink "$__cp_home/$__cp_rc")
            __cp_tgt="${__cp_tgt#./}"
            case "$__cp_tgt" in
                /*) ;;
                *) __cp_tgt="$__cp_home/$__cp_tgt" ;;
            esac
            if [ "$__cp_tgt" = "$__cp_path" ]; then
                echo "BLOCKED: $FILE_PATH is the target of the \$HOME/$__cp_rc symlink — editing it edits the live shell startup file for every future shell on this machine. If this is deliberate, edit it yourself or set CLAUDE_DISABLED_HOOKS=pre:edit:config-protection" >&2
                exit 2
            fi
        done
        # Not the live rc under any name → fall through to the linter/formatter case.
        ;;
esac

# Protected linter/formatter config files (ESLint, Prettier, Biome, Ruff, shellcheck, stylelint, markdownlint)
case "$BASENAME" in
    .eslintrc|.eslintrc.js|.eslintrc.cjs|.eslintrc.json|.eslintrc.yml|.eslintrc.yaml|eslint.config.js|eslint.config.mjs|eslint.config.cjs|eslint.config.ts|eslint.config.mts|.prettierrc|.prettierrc.js|.prettierrc.cjs|.prettierrc.json|.prettierrc.yml|.prettierrc.yaml|prettier.config.js|prettier.config.cjs|prettier.config.mjs|biome.json|biome.jsonc|.ruff.toml|ruff.toml|.shellcheckrc|.stylelintrc|.stylelintrc.json|.stylelintrc.yml|.markdownlint.json|.markdownlint.yaml|.markdownlintrc)
        echo "BLOCKED: Modifying $BASENAME is not allowed. Fix the source code to satisfy linter/formatter rules instead of weakening the config. If this is a legitimate config change, set CLAUDE_DISABLED_HOOKS=pre:edit:config-protection" >&2
        exit 2
        ;;
    *)
        echo "$INPUT"
        exit 0
        ;;
esac
