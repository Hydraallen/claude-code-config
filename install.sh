#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install Claude Code configuration files.

Options:
    --all               Install everything (default)
    --rules LANG...     Install common + specific language rules
                        Available: python, typescript, golang
    --skills            Install custom skills only
    --lessons           Install lessons.md template only
    --mcp               Install MCP servers only (Lark)
    --plugins           Install recommended plugins from marketplaces
    --claude-md         Install CLAUDE.md only
    --settings          Install settings.json only
    --dry-run           Show what would be installed without doing it
    -h, --help          Show this help

Examples:
    ./install.sh                        # Install everything
    ./install.sh --rules python golang  # Install common + Python + Go rules
    ./install.sh --plugins              # Install plugins only
    ./install.sh --dry-run              # Preview changes
EOF
}

DRY_RUN=false
INSTALL_ALL=true
INSTALL_RULES=false
INSTALL_SKILLS=false
INSTALL_LESSONS=false
INSTALL_MCP=false
INSTALL_PLUGINS=false
INSTALL_CLAUDE_MD=false
INSTALL_SETTINGS=false
RULE_LANGS=()

parse_args() {
    if [[ $# -eq 0 ]]; then
        return
    fi

    local has_component=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)
                INSTALL_ALL=true
                shift
                ;;
            --rules)
                has_component=true
                INSTALL_RULES=true
                shift
                while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do
                    RULE_LANGS+=("$1")
                    shift
                done
                ;;
            --skills)
                has_component=true
                INSTALL_SKILLS=true
                shift
                ;;
            --lessons)
                has_component=true
                INSTALL_LESSONS=true
                shift
                ;;
            --mcp)
                has_component=true
                INSTALL_MCP=true
                shift
                ;;
            --plugins)
                has_component=true
                INSTALL_PLUGINS=true
                shift
                ;;
            --claude-md)
                has_component=true
                INSTALL_CLAUDE_MD=true
                shift
                ;;
            --settings)
                has_component=true
                INSTALL_SETTINGS=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                # Legacy mode: treat bare args as language names
                has_component=true
                INSTALL_RULES=true
                RULE_LANGS+=("$1")
                shift
                ;;
        esac
    done

    # Only disable INSTALL_ALL when specific components are requested
    if $has_component; then
        INSTALL_ALL=false
    fi
}

backup_if_exists() {
    local target="$1"
    if [[ -e "$target" ]]; then
        local backup="${target}.backup.$(date +%Y%m%d%H%M%S)"
        if $DRY_RUN; then
            warn "Would backup: $target -> $backup"
        else
            cp -r "$target" "$backup"
            warn "Backed up: $target -> $backup"
        fi
    fi
}

install_claude_md() {
    info "Installing CLAUDE.md..."
    backup_if_exists "$CLAUDE_DIR/CLAUDE.md"
    if $DRY_RUN; then
        info "Would copy: CLAUDE.md -> $CLAUDE_DIR/CLAUDE.md"
    else
        cp "$SCRIPT_DIR/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"
        ok "CLAUDE.md installed"
    fi
}

install_settings() {
    info "Installing settings.json..."
    if [[ -f "$CLAUDE_DIR/settings.json" ]]; then
        warn "settings.json already exists -- please merge manually"
        warn "  Source: $SCRIPT_DIR/settings.json"
        warn "  Target: $CLAUDE_DIR/settings.json"
    else
        if $DRY_RUN; then
            info "Would copy: settings.json -> $CLAUDE_DIR/settings.json"
        else
            cp "$SCRIPT_DIR/settings.json" "$CLAUDE_DIR/settings.json"
            ok "settings.json installed"
        fi
    fi
}

install_rules() {
    info "Installing rules..."
    mkdir -p "$CLAUDE_DIR/rules"

    # Always install common rules
    if $DRY_RUN; then
        info "Would copy: rules/common/ -> $CLAUDE_DIR/rules/common/"
    else
        cp -r "$SCRIPT_DIR/rules/common" "$CLAUDE_DIR/rules/common"
        ok "Common rules installed"
    fi

    # Install language-specific rules
    local langs=()
    if [[ ${#RULE_LANGS[@]} -gt 0 ]]; then
        langs=("${RULE_LANGS[@]}")
    fi
    if [[ ${#langs[@]} -eq 0 ]]; then
        for lang_dir in "$SCRIPT_DIR"/rules/*/; do
            local lang
            lang=$(basename "$lang_dir")
            [[ "$lang" == "common" || "$lang" == "README.md" ]] && continue
            langs+=("$lang")
        done
    fi

    for lang in "${langs[@]}"; do
        if [[ -d "$SCRIPT_DIR/rules/$lang" ]]; then
            if $DRY_RUN; then
                info "Would copy: rules/$lang/ -> $CLAUDE_DIR/rules/$lang/"
            else
                cp -r "$SCRIPT_DIR/rules/$lang" "$CLAUDE_DIR/rules/$lang"
                ok "$lang rules installed"
            fi
        else
            error "Language rules not found: $lang"
        fi
    done

    if $DRY_RUN; then
        info "Would copy: rules/README.md -> $CLAUDE_DIR/rules/README.md"
    else
        cp "$SCRIPT_DIR/rules/README.md" "$CLAUDE_DIR/rules/README.md"
    fi
}

install_skills() {
    info "Installing custom skills..."
    mkdir -p "$CLAUDE_DIR/skills"

    for skill_dir in "$SCRIPT_DIR"/skills/*/; do
        local skill
        skill=$(basename "$skill_dir")
        if $DRY_RUN; then
            info "Would copy: skills/$skill/ -> $CLAUDE_DIR/skills/$skill/"
        else
            cp -r "$skill_dir" "$CLAUDE_DIR/skills/$skill"
            ok "Skill installed: $skill"
        fi
    done
}

install_lessons() {
    info "Installing lessons.md template..."
    local target="$CLAUDE_DIR/lessons.md"

    if [[ -f "$target" ]]; then
        warn "lessons.md already exists -- skipping"
    else
        if $DRY_RUN; then
            info "Would copy: lessons.md -> $target"
        else
            cp "$SCRIPT_DIR/lessons.md" "$target"
            ok "lessons.md template installed to $target"
        fi
    fi
}

install_mcp() {
    info "Installing MCP servers..."

    if ! command -v claude &>/dev/null; then
        error "Claude Code CLI not found. Install it first: https://claude.com/claude-code"
        return 1
    fi

    # Lark MCP
    if $DRY_RUN; then
        info "Would add MCP server: lark-mcp (stdio)"
    else
        claude mcp add --scope user --transport stdio lark-mcp \
            -- npx -y @larksuiteoapi/lark-mcp mcp -a YOUR_APP_ID -s YOUR_APP_SECRET 2>/dev/null && \
            ok "MCP server added: lark-mcp" || \
            warn "MCP server lark-mcp may already exist"
        warn "Replace YOUR_APP_ID and YOUR_APP_SECRET with your Feishu credentials"
    fi
}

install_plugins() {
    info "Installing plugins from marketplaces..."

    if ! command -v claude &>/dev/null; then
        error "Claude Code CLI not found. Install it first: https://claude.com/claude-code"
        return 1
    fi

    # Marketplaces: "name|github_repo"
    local marketplace_list=(
        "anthropic-agent-skills|anthropics/skills"
        "everything-claude-code|affaan-m/everything-claude-code"
        "ai-research-skills|zechenzhangAGI/AI-research-SKILLs"
        "claude-plugins-official|anthropics/claude-plugins-official"
        "thedotmack|thedotmack/claude-mem"
    )

    # Plugins
    PLUGINS=(
        "document-skills@anthropic-agent-skills"
        "example-skills@anthropic-agent-skills"
        "everything-claude-code@everything-claude-code"
        "claude-mem@thedotmack"
        "fine-tuning@ai-research-skills"
        "post-training@ai-research-skills"
        "inference-serving@ai-research-skills"
        "distributed-training@ai-research-skills"
        "optimization@ai-research-skills"
        "frontend-design@claude-plugins-official"
        "context7@claude-plugins-official"
        "superpowers@claude-plugins-official"
        "code-review@claude-plugins-official"
        "github@claude-plugins-official"
        "playwright@claude-plugins-official"
        "feature-dev@claude-plugins-official"
        "code-simplifier@claude-plugins-official"
        "ralph-loop@claude-plugins-official"
        "commit-commands@claude-plugins-official"
    )

    # Step 1: Add marketplaces
    info "Adding marketplaces..."
    for entry in "${marketplace_list[@]}"; do
        local marketplace="${entry%%|*}"
        local repo="${entry##*|}"
        if $DRY_RUN; then
            info "Would add marketplace: $marketplace (github.com/$repo)"
        else
            claude plugin marketplace add "https://github.com/$repo" 2>/dev/null && \
                ok "Marketplace added: $marketplace" || \
                warn "Marketplace $marketplace may already exist"
        fi
    done

    # Step 2: Install plugins
    info "Installing plugins..."
    for entry in "${PLUGINS[@]}"; do
        local plugin_name="${entry%%@*}"
        local marketplace="${entry##*@}"
        if $DRY_RUN; then
            info "Would install plugin: $plugin_name from $marketplace"
        else
            claude plugin install "${plugin_name}@${marketplace}" 2>/dev/null && \
                ok "Plugin installed: $plugin_name" || \
                warn "Plugin $plugin_name may already be installed"
        fi
    done
}

main() {
    parse_args "$@"

    echo ""
    echo "========================================="
    echo "  Claude Code Configuration Installer"
    echo "========================================="
    echo ""

    if $DRY_RUN; then
        warn "DRY RUN MODE -- no changes will be made"
        echo ""
    fi

    mkdir -p "$CLAUDE_DIR"

    if $INSTALL_ALL; then
        install_claude_md
        install_settings
        install_rules
        install_skills
        install_lessons
        install_mcp
        install_plugins
    else
        $INSTALL_CLAUDE_MD && install_claude_md
        $INSTALL_SETTINGS && install_settings
        $INSTALL_RULES && install_rules
        $INSTALL_SKILLS && install_skills
        $INSTALL_LESSONS && install_lessons
        $INSTALL_MCP && install_mcp
        $INSTALL_PLUGINS && install_plugins
    fi

    echo ""
    ok "Installation complete!"
    echo ""
    info "Next steps:"
    echo "  1. Restart Claude Code for changes to take effect"
    echo "  2. Replace YOUR_APP_ID/YOUR_APP_SECRET in Lark MCP config"
    echo "  3. Customize CLAUDE.md for your specific projects"
    echo "  4. Review settings.json and merge with your existing config"
    echo ""
}

main "$@"
