#Requires -Version 5.1
<#
.SYNOPSIS
    Awesome Claude Code Configuration Installer (Windows)
.DESCRIPTION
    https://github.com/Mizoreww/awesome-claude-code-config
.EXAMPLE
    .\install.ps1                  # Interactive selector
    .\install.ps1 -All             # Install everything (non-interactive)
    .\install.ps1 -Uninstall       # Uninstall everything
    .\install.ps1 -DryRun          # Preview changes
    # Remote install:
    irm https://raw.githubusercontent.com/Mizoreww/awesome-claude-code-config/main/install.ps1 | iex
#>

# Wrap in & { param() ... } to isolate parameter scope.
# In `irm | iex` mode, $args in the outer scope may contain garbage tokens
# (e.g. "adversarial-review") leaked from script parsing. We filter $args
# to only pass recognized switch-style arguments (starting with "-").
$_safeArgs = @( $args | Where-Object { $_ -is [string] -and $_ -match '^-' } )
& {
param(
    [switch]$All,
    [switch]$Uninstall,
    [switch]$Version,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$CLAUDE_DIR = Join-Path $env:USERPROFILE ".claude"
$script:REPO_OWNER = if ($env:REPO_OWNER) { $env:REPO_OWNER } else { "Hydraallen" }
$script:REPO_NAME = if ($env:REPO_NAME) { $env:REPO_NAME } else { "claude-code-config" }
$script:REPO_BRANCH = if ($env:REPO_BRANCH) { $env:REPO_BRANCH } else { "main" }
# Validate metadata so the assembled URLs stay well-formed and safe.
if ($script:REPO_OWNER -notmatch '^[A-Za-z0-9._-]+$') { Write-Host "Invalid REPO_OWNER: $($script:REPO_OWNER)" -ForegroundColor Red; exit 1 }
if ($script:REPO_NAME -notmatch '^[A-Za-z0-9._-]+$') { Write-Host "Invalid REPO_NAME: $($script:REPO_NAME)" -ForegroundColor Red; exit 1 }
if ($script:REPO_BRANCH -notmatch '^[A-Za-z0-9._/-]+$') { Write-Host "Invalid REPO_BRANCH: $($script:REPO_BRANCH)" -ForegroundColor Red; exit 1 }
$script:REPO_URL = "https://github.com/$($script:REPO_OWNER)/$($script:REPO_NAME)"
$VERSION_STAMP_FILE = Join-Path $CLAUDE_DIR ".awesome-claude-code-config-version"

# --- Colors ----------------------------------------------------------------

function Write-Info  { param([string]$Msg) Write-Host "[INFO] " -ForegroundColor Blue -NoNewline; Write-Host $Msg }
function Write-Ok    { param([string]$Msg) Write-Host "[OK] " -ForegroundColor Green -NoNewline; Write-Host $Msg }
function Write-Warn  { param([string]$Msg) Write-Host "[WARN] " -ForegroundColor Yellow -NoNewline; Write-Host $Msg }
function Write-Err   { param([string]$Msg) Write-Host "[ERROR] " -ForegroundColor Red -NoNewline; Write-Host $Msg }

# --- Retry wrapper ---------------------------------------------------------

function Invoke-Retry {
    param(
        [int]$MaxAttempts,
        [int]$DelaySeconds,
        [string]$Description,
        [scriptblock]$Action
    )
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            & $Action
            return $true
        } catch {
            if ($attempt -lt $MaxAttempts) {
                Write-Warn "$Description failed (attempt $attempt/$MaxAttempts), retrying in ${DelaySeconds}s..."
                Start-Sleep -Seconds $DelaySeconds
            } else {
                Write-Warn "$Description failed after $MaxAttempts attempts, skipping."
            }
        }
    }
    return $false
}

# --- Remote install detection ----------------------------------------------

$script:SCRIPT_DIR = ""
$script:REMOTE_MODE = $false
$script:REMOTE_DRY_RUN = $false
$script:InstallWarnings = 0
$script:InstallCritical = 0

function Initialize-ScriptDir {
    $script:SCRIPT_DIR = $PSScriptRoot

    if ($script:SCRIPT_DIR -and (Test-Path (Join-Path $script:SCRIPT_DIR "CLAUDE.md"))) {
        $script:REMOTE_MODE = $false
        return
    }

    # Remote mode: would download zip to temp dir. In DryRun, short-circuit
    # BEFORE any network/temp write: print a sanitized planned-source message
    # and leave source enumeration to Main's remote-dry-run plan. Neither
    # USERPROFILE nor temp is touched.
    $script:REMOTE_MODE = $true
    if ($DryRun) {
        $ver = if ($env:VERSION) { $env:VERSION } else { $script:REPO_BRANCH }
        $zipUrl = "$($script:REPO_URL)/archive/refs/heads/$ver.zip"
        if ($ver -match '^v\d') { $zipUrl = "$($script:REPO_URL)/archive/refs/tags/$ver.zip" }
        $script:REMOTE_DRY_RUN = $true
        Write-Info "Remote DryRun: would download $ver from $zipUrl (no network/temp write)"
        return
    }

    $tmpdir = Join-Path ([System.IO.Path]::GetTempPath()) "claude-config-$(Get-Random)"
    New-Item -ItemType Directory -Path $tmpdir -Force | Out-Null

    $ver = if ($env:VERSION) { $env:VERSION } else { $script:REPO_BRANCH }
    $zipUrl = "$($script:REPO_URL)/archive/refs/heads/$ver.zip"
    if ($ver -match '^v\d') {
        $zipUrl = "$($script:REPO_URL)/archive/refs/tags/$ver.zip"
    }

    Write-Info "Remote mode: downloading $ver..."
    $zipPath = Join-Path $tmpdir "source.zip"

    $ok = Invoke-Retry -MaxAttempts 5 -DelaySeconds 3 -Description "Download source zip" -Action {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
    }
    if (-not $ok) {
        Write-Err "Failed to download source after retries. Cannot continue in remote mode."
        exit 1
    }

    Expand-Archive -Path $zipPath -DestinationPath $tmpdir -Force
    $extracted = Get-ChildItem -Path $tmpdir -Directory | Where-Object { $_.Name -ne "source.zip" } | Select-Object -First 1
    $script:SCRIPT_DIR = $extracted.FullName
    Write-Ok "Source downloaded to temporary directory"
}

# --- Version management ----------------------------------------------------

function Get-SourceVersion {
    $vf = Join-Path $SCRIPT_DIR "VERSION"
    if (Test-Path $vf) { return (Get-Content $vf -Raw).Trim() }
    return "unknown"
}

function Get-InstalledVersion {
    if (Test-Path $VERSION_STAMP_FILE) { return (Get-Content $VERSION_STAMP_FILE -Raw).Trim() }
    return "not installed"
}

function Get-RemoteVersion {
    $url = "https://raw.githubusercontent.com/$($script:REPO_OWNER)/$($script:REPO_NAME)/$($script:REPO_BRANCH)/VERSION"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $result = (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10).Content.Trim()
        if ($result) { return $result }
    } catch {}
    return "unavailable"
}

function Show-Version {
    $sv = Get-SourceVersion
    $iv = Get-InstalledVersion
    $rv = Get-RemoteVersion
    Write-Host "awesome-claude-code-config version info:"
    Write-Host "  Source:    $sv"
    Write-Host "  Installed: $iv"
    Write-Host "  Remote:    $rv"
    if ($iv -ne "not installed" -and $rv -ne "unavailable" -and $iv -ne $rv) {
        Write-Warn "Update available: $iv -> $rv"
    }
}

function Save-VersionStamp {
    $ver = Get-SourceVersion
    if ($ver -ne "unknown") {
        $ver | Set-Content -Path $VERSION_STAMP_FILE -NoNewline
    }
}

# --- Confirm prompt --------------------------------------------------------

function Confirm-Action {
    param([string]$Prompt = "Continue?")
    if ($Force) { return $true }
    $answer = Read-Host "$Prompt [y/N]"
    return ($answer -match '^[Yy]$')
}

# Retired Skill ownership tombstones.
$RETIRED_HARNESS_WORKFLOW_SHA256 = "d897cbfec20f87b553cbbe0f0541a1169f045492881b78b566149d15af1e68ba"
function Test-SafeRetiredSkillName { param([string]$Name); return -not [string]::IsNullOrEmpty($Name) -and $Name -ne "." -and $Name -ne ".." -and $Name -match '^[A-Za-z0-9][A-Za-z0-9._-]*$' }
function Remove-RetiredMattpocockSkills {
    $manifest = Join-Path $CLAUDE_DIR ".mattpocock-skills"; if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { return }
    foreach ($skillName in (Get-Content -LiteralPath $manifest)) { if ([string]::IsNullOrEmpty($skillName)) { continue }; if (-not (Test-SafeRetiredSkillName $skillName)) { Write-Warn "Skipping unsafe retired skill manifest entry"; continue }; $skillPath = Join-Path (Join-Path $CLAUDE_DIR "skills") $skillName; if (-not (Test-Path -LiteralPath $skillPath -PathType Container)) { continue }; if ($DryRun) { Write-Info "Would remove retired manifest-owned skill: $skillName" } else { Remove-Item -LiteralPath $skillPath -Recurse -Force; Write-Ok "Removed retired manifest-owned skill: $skillName" } }
    if ($DryRun) { Write-Info "Would remove retired skill manifest: $manifest" } else { Remove-Item -LiteralPath $manifest -Force; Write-Ok "Removed retired skill manifest" }
}
function Remove-RetiredHarnessWorkflow {
    $skillDir = Join-Path (Join-Path $CLAUDE_DIR "skills") "harness-workflow"; if (-not (Test-Path -LiteralPath $skillDir -PathType Container)) { return }; $skillFile = Join-Path $skillDir "SKILL.md"; if (-not (Test-Path -LiteralPath $skillFile -PathType Leaf)) { Write-Warn "Retired harness-workflow: cannot verify ownership; preserving directory"; return }; try { $digest = (Get-FileHash -Algorithm SHA256 -LiteralPath $skillFile).Hash.ToLowerInvariant() } catch { Write-Warn "Retired harness-workflow: cannot verify ownership; preserving directory"; return }; if ($digest -ne $RETIRED_HARNESS_WORKFLOW_SHA256) { Write-Warn "Retired harness-workflow is modified or user-authored; preserving directory"; return }; if ($DryRun) { Write-Info "Would remove retired managed skill file: harness-workflow/SKILL.md"; return }
    Remove-Item -LiteralPath $skillFile -Force
    if (@(Get-ChildItem -LiteralPath $skillDir -Force).Count -eq 0) { Remove-Item -LiteralPath $skillDir -Force; Write-Ok "Removed retired managed skill: harness-workflow" }
    else { Write-Warn "Removed retired managed harness-workflow/SKILL.md; preserved additional content" }
}
function Remove-RetiredEnabledPlugins {
    $settings = Join-Path $CLAUDE_DIR "settings.json"; if (-not (Test-Path -LiteralPath $settings -PathType Leaf)) { return }
    try { $obj = Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json } catch { Write-Warn "settings.json is invalid - cannot remove retired enabled plugins safely"; return }
    $found = $false; foreach ($pkg in $PLUGINS_REMOVED) { if ($obj.enabledPlugins -and $obj.enabledPlugins.PSObject.Properties.Name -contains $pkg) { $found = $true; if ($DryRun) { Write-Info "Would remove retired enabled plugin: $pkg" } else { $obj.enabledPlugins.PSObject.Properties.Remove($pkg) } } }
    if (-not $found -or $DryRun) { return }
    $tmp = Join-Path (Split-Path $settings -Parent) ("settings.json.tmp." + [Guid]::NewGuid().ToString("N"))
    try { $obj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tmp -Encoding UTF8; Get-Content -LiteralPath $tmp -Raw | ConvertFrom-Json | Out-Null; [System.IO.File]::Replace($tmp, $settings, $null); Write-Ok "Removed retired enabled plugin settings" } catch { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue; Write-Warn "Could not remove retired enabled plugins safely: $_" }
}
function Remove-RetiredSkills { Remove-RetiredMattpocockSkills; Remove-RetiredHarnessWorkflow }

# --- Plugin groups ---------------------------------------------------------

$PLUGINS_ESSENTIAL = @(
    "andrej-karpathy-skills@karpathy-skills"
    "superpowers@claude-plugins-official"
    "context7@claude-plugins-official"
    "commit-commands@claude-plugins-official"
    "document-skills@anthropic-agent-skills"
    "playwright@claude-plugins-official"
    "feature-dev@claude-plugins-official"
    "code-simplifier@claude-plugins-official"
    "ralph-loop@claude-plugins-official"
    "example-skills@anthropic-agent-skills"
    "github@claude-plugins-official"
)

# Optional plugins: default OFF, installed only via explicit -All or manual opt-in
$PLUGINS_OPTIONAL = @(
    "ecc@ecc"
    "frontend-slides@frontend-slides"
    "ppt-master@ppt-master"
)

$PLUGINS_CLAUDE_MEM = @(
    "claude-mem@thedotmack"
)

$PLUGINS_AI_RESEARCH = @(
    "tokenization@ai-research-skills"
    "fine-tuning@ai-research-skills"
    "post-training@ai-research-skills"
    "inference-serving@ai-research-skills"
    "distributed-training@ai-research-skills"
    "optimization@ai-research-skills"
)

$PLUGINS_PUA = @(
    "pua@pua-skills"
)

# Plugins/marketplaces retired or renamed upstream. Re-running the installer
# uninstalls these stale ids and removes their orphaned marketplaces so a
# rename (e.g. everything-claude-code -> ecc) self-heals on the next run.
$RETIRED_PLUGINS = @(
    "frontend-design@claude-plugins-official"
    "everything-claude-code@everything-claude-code"
    "health@claude-health"
)
$RETIRED_MARKETPLACES = @(
    "everything-claude-code"
    "claude-health"
)

# Tombstones: plugins removed upstream. Stripped from a user's enabledPlugins
# on upgrade and uninstalled on -Uninstall, so "removed" plugins don't linger.
$PLUGINS_REMOVED = @(
    "frontend-design@claude-plugins-official"
    "everything-claude-code@everything-claude-code"
)

$MARKETPLACE_LIST = @(
    @{ Name = "anthropic-agent-skills"; Repo = "anthropics/skills" }
    @{ Name = "ecc"; Repo = "affaan-m/everything-claude-code" }
    @{ Name = "ai-research-skills"; Repo = "zechenzhangAGI/AI-research-SKILLs" }
    @{ Name = "claude-plugins-official"; Repo = "anthropics/claude-plugins-official" }
    @{ Name = "thedotmack"; Repo = "thedotmack/claude-mem" }
    @{ Name = "pua-skills"; Repo = "tanweai/pua" }
    @{ Name = "openai-codex"; Repo = "openai/codex-plugin-cc" }
    @{ Name = "frontend-slides"; Repo = "zarazhangrui/frontend-slides" }
    @{ Name = "ppt-master"; Repo = "hugohe3/ppt-master" }
    @{ Name = "karpathy-skills"; Repo = "forrestchang/andrej-karpathy-skills" }
)

# Plugins selected for THIS run (deduped), set by Install-Plugins so that
# Remove-UnlistedPlugins / Update-InstalledPlugins can reconcile against it.
# Mirrors RESOLVED_PLUGINS in install.sh.
$script:ResolvedPlugins = @()

# --- Plugin reconciliation helpers (mirror install.sh) ---------------------

# Union of every installer-managed plugin group (the "catalogue"). Anything
# installed that is NOT in this set is a user-owned third-party plugin and must
# be preserved. Mirrors build_plugin_catalogue() in install.sh.
function Get-PluginCatalogue {
    $all = @()
    $all += $PLUGINS_ESSENTIAL
    $all += $PLUGINS_OPTIONAL
    $all += $PLUGINS_CLAUDE_MEM
    $all += $PLUGINS_AI_RESEARCH
    $all += $PLUGINS_PUA
    return ($all | Select-Object -Unique)
}

# Pure decision logic: given the catalogue, the selected-this-run set, and the
# installed set, return the installed keys that should be UNINSTALLED — those in
# the catalogue AND not selected this run (rule 1). Non-catalogue plugins are
# preserved (rule 4); selected plugins are reinstalled, not pruned (rule 2).
# Mirrors compute_plugins_to_prune() in install.sh.
function Get-PluginsToPrune {
    param(
        [string[]]$Catalogue = @(),
        [string[]]$Selected = @(),
        [string[]]$Installed = @()
    )
    $result = @()
    foreach ($entry in $Installed) {
        if (-not $entry) { continue }
        if ($Catalogue -notcontains $entry) { continue }  # rule 4: preserve
        if ($Selected -contains $entry) { continue }       # rule 2: reinstall
        $result += $entry                                  # rule 1: prune
    }
    return $result
}

# Read the installed plugin keys from installed_plugins.json (native JSON, no jq).
function Get-InstalledPluginKeys {
    $listJson = Join-Path $env:USERPROFILE ".claude\plugins\installed_plugins.json"
    if (-not (Test-Path $listJson)) { return @() }
    try {
        $parsed = Get-Content $listJson -Raw | ConvertFrom-Json
        if ($parsed.PSObject.Properties['plugins']) {
            return @($parsed.plugins.PSObject.Properties.Name)
        }
    } catch { }
    return @()
}

# --- Interactive menu ------------------------------------------------------

function Show-InteractiveMenu {
    # Two-level menu: groups contain items, Enter opens sub-menu
    $groups = @(
        @{ Label = "Core"; Hint = ""; Items = @(
            @{ Label = "CLAUDE.md";       Desc = "Global instructions template";      Default = $true;  Id = "claude-md" }
            @{ Label = "settings.json";   Desc = "Smart-merged Claude Code settings"; Default = $true;  Id = "settings" }
            @{ Label = "Common rules";    Desc = "Coding style, git, security, testing"; Default = $true; Id = "rules-common" }
            @{ Label = "StatusLine";      Desc = "Gradient bars + Anthropic/GLM 5h quota"; Default = $true; Id = "hooks" }
            @{ Label = "Lessons";         Desc = "lessons.md template + SessionStart hook"; Default = $true; Id = "lessons" }
            @{ Label = "Search agent";    Desc = "Jeff read-only web search agent"; Default = $true; Id = "agents" }
        )}
        @{ Label = "Language Rules"; Hint = "only install what your projects need"; Items = @(
            @{ Label = "Python rules";    Desc = "PEP 8, pytest, type hints, bandit"; Default = $false; Id = "rules-python" }
            @{ Label = "TypeScript rules"; Desc = "Zod, Playwright, immutability";    Default = $false; Id = "rules-ts" }
            @{ Label = "Go rules";        Desc = "gofmt, table-driven tests, gosec";  Default = $false; Id = "rules-go" }
        )}
        @{ Label = "Review"; Hint = "adversarial-review and Codex are mutually exclusive"; Items = @(
            @{ Label = "code-review plugin"; Desc = "PR code review (claude-plugins-official)"; Default = $true; Id = "review-code-review" }
            @{ Label = "adversarial-review"; Desc = "Cross-model adversarial review (poteto/noodle); needs codex CLI"; Default = $false; Id = "review-adversarial" }
            @{ Label = "Codex CLI"; Desc = "Codex adversarial review (openai/codex)"; Default = $false; Id = "review-codex" }
        )}
        @{ Label = "Workflow"; Hint = "planning, iteration, code quality, meta-config"; Items = @(
            @{ Label = "andrej-karpathy-skills"; Desc = "Karpathy coding guidelines (Think-First, Simplicity, Surgical)"; Default = $true; Id = "plug-andrej-karpathy-skills" }
            @{ Label = "superpowers";     Desc = "Planning, brainstorming, TDD, debugging"; Default = $true;  Id = "plug-superpowers" }
            @{ Label = "feature-dev";     Desc = "Guided feature development";        Default = $true;  Id = "plug-feature-dev" }
            @{ Label = "ralph-loop";      Desc = "Automated iteration loop";          Default = $true;  Id = "plug-ralph-loop" }
            @{ Label = "commit-commands"; Desc = "git commit / push / PR workflow";   Default = $true;  Id = "plug-commit-commands" }
            @{ Label = "code-simplifier"; Desc = "Code simplification & cleanup";     Default = $true;  Id = "plug-code-simplifier" }
            @{ Label = "ecc"; Desc = "Everything Claude Code: TDD, security, database, Go/Python/Spring Boot"; Default = $true; Id = "plug-everything-claude-code" }
            @{ Label = "update-config";   Desc = "Configure Claude Code via settings.json (skill)"; Default = $true; Id = "skill-update-config" }
        )}
        @{ Label = "Integrations"; Hint = "external tools & services"; Items = @(
            @{ Label = "context7";        Desc = "Real-time library documentation";   Default = $true;  Id = "plug-context7" }
            @{ Label = "github";          Desc = "GitHub integration (issues, PRs, workflows)"; Default = $true;  Id = "plug-github" }
            @{ Label = "playwright";      Desc = "Browser automation & E2E testing";  Default = $true;  Id = "plug-playwright" }
        )}
        @{ Label = "Design & Content"; Hint = "documents, UI, creative artifacts, humanization"; Items = @(
            @{ Label = "document-skills"; Desc = "Document processing (PDF, DOCX, PPTX, XLSX)"; Default = $true; Id = "plug-document-skills" }
            @{ Label = "example-skills";  Desc = "Frontend/design/canvas/algorithmic-art skills"; Default = $true;  Id = "plug-example-skills" }
            @{ Label = "humanizer";       Desc = "Remove AI writing patterns (English, blader) (skill)"; Default = $true; Id = "skill-humanizer" }
            @{ Label = "humanizer-zh";    Desc = "Remove AI writing patterns (Chinese, op7418) (skill)"; Default = $false; Id = "skill-humanizer-zh" }
        )}
        @{ Label = "Slides"; Hint = "AI slide / PPTX generation | default off"; Items = @(
            @{ Label = "frontend-slides"; Desc = "HTML slide generator with PPT conversion (zarazhangrui)"; Default = $false; Id = "plug-frontend-slides" }
            @{ Label = "ppt-master";      Desc = "Editable PPTX from PDF/DOCX/URL/Markdown; needs pip install (hugohe3)"; Default = $false; Id = "plug-ppt-master" }
        )}
        @{ Label = "Memory & Lifestyle"; Hint = "session memory and personal productivity"; Items = @(
            @{ Label = "claude-mem";      Desc = "Cross-session memory (~3k tokens/session)"; Default = $false; Id = "plug-claude-mem" }
            @{ Label = "PUA";             Desc = "AI agent productivity booster (pua, pua-en, pua-ja)"; Default = $false; Id = "plug-pua" }
        )}
        @{ Label = "Academic Research"; Hint = "training/inference plugins + paper-reading & DeepXiv skills"; Items = @(
            @{ Label = "paper-reading";   Desc = "Research paper summarization (skill)"; Default = $true; Id = "skill-paper-reading" }
            @{ Label = "cheatsheet-creator"; Desc = "Exam cheatsheet from lectures/homework/past exams (skill)"; Default = $true; Id = "skill-cheatsheet-creator" }
            @{ Label = "tokenization";    Desc = "Tokenizer training & usage";        Default = $false; Id = "plug-tokenization" }
            @{ Label = "fine-tuning";     Desc = "Model fine-tuning";                 Default = $false; Id = "plug-fine-tuning" }
            @{ Label = "post-training";   Desc = "Post-training (RLHF, DPO, GRPO)";  Default = $false; Id = "plug-post-training" }
            @{ Label = "inference-serving"; Desc = "Inference serving (vLLM, SGLang, TensorRT)"; Default = $false; Id = "plug-inference-serving" }
            @{ Label = "distributed-training"; Desc = "Distributed training (DeepSpeed, FSDP, Megatron)"; Default = $false; Id = "plug-distributed-training" }
            @{ Label = "optimization";    Desc = "Quantization & optimization (GPTQ, AWQ, Flash Attn)"; Default = $false; Id = "plug-optimization" }
            @{ Label = "deepxiv-cli";      Desc = "arXiv/PMC paper search & reading CLI skill"; Default = $false; Id = "deepxiv-cli" }
            @{ Label = "deepxiv-trending-digest"; Desc = "Trending paper digest generation"; Default = $false; Id = "deepxiv-trending-digest" }
            @{ Label = "deepxiv-baseline-table"; Desc = "Baseline comparison table from papers"; Default = $false; Id = "deepxiv-baseline-table" }
        )}
        @{ Label = "MCP Servers"; Hint = ""; Items = @(
            @{ Label = "Playwright MCP"; Desc = "Browser automation MCP server";        Default = $true;  Id = "mcp" }
            @{ Label = "Lark/Feishu MCP"; Desc = "Feishu/Lark integration -- needs App ID/Secret, ~1GB RAM/session"; Default = $false; Id = "mcp-lark" }
        )}
    )

    # Flatten groups into parallel arrays
    $allItems = @()
    $groupStart = @()
    $groupEnd = @()
    foreach ($g in $groups) {
        $groupStart += $allItems.Count
        $allItems += $g.Items
        $groupEnd += ($allItems.Count - 1)
    }
    $n = $allItems.Count
    $numGroups = $groups.Count

    # Initialize selections from defaults
    $selected = @()
    for ($i = 0; $i -lt $n; $i++) { $selected += $allItems[$i].Default }

    $cursor = 0
    $submitIndex = $numGroups

    # Helper: enforce review mutual exclusion
    function Enforce-ReviewMutex($idx) {
        if ($selected[$idx]) {
            $id = $allItems[$idx].Id
            $reviewStart = $groupStart[2]; $reviewEnd = $groupEnd[2]
            if ($id -eq "review-adversarial") {
                for ($j = $reviewStart; $j -le $reviewEnd; $j++) {
                    if ($allItems[$j].Id -eq "review-codex") { $selected[$j] = $false }
                }
            } elseif ($id -eq "review-codex") {
                for ($j = $reviewStart; $j -le $reviewEnd; $j++) {
                    if ($allItems[$j].Id -eq "review-adversarial") { $selected[$j] = $false }
                }
            }
        }
    }

    $savedCursorVisible = [Console]::CursorVisible
    [Console]::CursorVisible = $false

    try {
        # --- Main menu loop ---
        while ($true) {
            [Console]::Clear()
            Write-Host ""
            Write-Host "  =========================================" -ForegroundColor White
            Write-Host "  Awesome Claude Code Config Installer" -ForegroundColor White
            Write-Host "  $(Get-SourceVersion)" -ForegroundColor White
            Write-Host "  =========================================" -ForegroundColor White
            Write-Host ""
            Write-Host "  " -NoNewline; Write-Host "Up/Down move  Enter/Right open sub-menu  a=all n=none d=defaults q=quit" -ForegroundColor DarkGray
            Write-Host ""

            for ($g = 0; $g -lt $numGroups; $g++) {
                $cnt = 0
                for ($j = $groupStart[$g]; $j -le $groupEnd[$g]; $j++) {
                    if ($selected[$j]) { $cnt++ }
                }
                $tot = $groupEnd[$g] - $groupStart[$g] + 1
                $countStr = "[$cnt/$tot]".PadRight(7)
                $label = $groups[$g].Label.PadRight(24)
                $isCursor = ($g -eq $cursor)

                if ($isCursor) {
                    Write-Host "  " -NoNewline
                    Write-Host "> " -ForegroundColor Green -NoNewline
                    Write-Host "$countStr " -NoNewline
                    Write-Host $label -ForegroundColor White -NoNewline
                } else {
                    Write-Host "    $countStr $label" -NoNewline
                }
                if ($groups[$g].Hint) {
                    Write-Host " ($($groups[$g].Hint))" -ForegroundColor DarkGray
                } else {
                    Write-Host ""
                }
            }
            Write-Host ""

            if ($cursor -eq $submitIndex) {
                Write-Host "  " -NoNewline
                Write-Host "> " -ForegroundColor Green -NoNewline
                Write-Host "[ Submit ]" -ForegroundColor Green
            } else {
                Write-Host "     " -NoNewline
                Write-Host "[ Submit ]" -ForegroundColor DarkGray
            }
            Write-Host ""

            $key = [Console]::ReadKey($true)

            # Check submit first
            if ($cursor -eq $submitIndex -and ($key.Key -eq [ConsoleKey]::Enter -or $key.Key -eq [ConsoleKey]::Spacebar)) { break }

            # RightArrow opens a group's sub-menu, same as Enter on a group row.
            # Enter on the Submit row commits; RightArrow on Submit does nothing.
            $openSubMenu = ($key.Key -eq [ConsoleKey]::Enter -or $key.Key -eq [ConsoleKey]::RightArrow) -and $cursor -lt $numGroups
            switch ($key.Key) {
                ([ConsoleKey]::UpArrow)   { if ($cursor -gt 0) { $cursor-- } }
                ([ConsoleKey]::DownArrow) { if ($cursor -lt $submitIndex) { $cursor++ } }
                { $_ -eq [ConsoleKey]::Enter -or $_ -eq [ConsoleKey]::RightArrow } {
                    if ($openSubMenu) {
                        # Enter sub-menu
                        $subG = $cursor
                        $subItems = $groups[$subG].Items
                        $subN = $subItems.Count
                        $subCursor = 0
                        $inSub = $true
                        while ($inSub) {
                            [Console]::Clear()
                            Write-Host ""
                            Write-Host "  =========================================" -ForegroundColor White
                            Write-Host "  $($groups[$subG].Label)" -ForegroundColor Cyan -NoNewline
                            if ($groups[$subG].Hint) { Write-Host "  ($($groups[$subG].Hint))" -ForegroundColor DarkGray } else { Write-Host "" }
                            Write-Host "  =========================================" -ForegroundColor White
                            Write-Host ""
                            Write-Host "  " -NoNewline; Write-Host "Up/Down move  Space toggle  Left/Esc back  Enter on [Back] to return" -ForegroundColor DarkGray
                            Write-Host ""

                            for ($j = 0; $j -lt $subN; $j++) {
                                $absIdx = $groupStart[$subG] + $j
                                $isCur = ($j -eq $subCursor)
                                if ($isCur) { Write-Host "  " -NoNewline; Write-Host "> " -ForegroundColor Green -NoNewline } else { Write-Host "    " -NoNewline }
                                Write-Host "[" -NoNewline
                                if ($selected[$absIdx]) { Write-Host "x" -ForegroundColor Green -NoNewline } else { Write-Host " " -NoNewline }
                                Write-Host "] " -NoNewline
                                $lbl = $allItems[$absIdx].Label.PadRight(28)
                                if ($isCur) { Write-Host $lbl -ForegroundColor White -NoNewline } else { Write-Host $lbl -NoNewline }
                                Write-Host " $($allItems[$absIdx].Desc)" -ForegroundColor DarkGray
                            }
                            Write-Host ""
                            if ($subCursor -eq $subN) {
                                Write-Host "  " -NoNewline; Write-Host "> " -ForegroundColor Green -NoNewline; Write-Host "[ Back ]" -ForegroundColor Yellow
                            } else {
                                Write-Host "     " -NoNewline; Write-Host "[ Back ]" -ForegroundColor DarkGray
                            }
                            Write-Host ""

                            $subKey = [Console]::ReadKey($true)
                            switch ($subKey.Key) {
                                ([ConsoleKey]::UpArrow)   { if ($subCursor -gt 0) { $subCursor-- } }
                                ([ConsoleKey]::DownArrow) { if ($subCursor -lt $subN) { $subCursor++ } }
                                ([ConsoleKey]::Spacebar) {
                                    if ($subCursor -lt $subN) {
                                        $absIdx = $groupStart[$subG] + $subCursor
                                        $selected[$absIdx] = -not $selected[$absIdx]
                                        Enforce-ReviewMutex $absIdx
                                    }
                                }
                                ([ConsoleKey]::Enter) {
                                    if ($subCursor -eq $subN) { $inSub = $false }
                                    else {
                                        $absIdx = $groupStart[$subG] + $subCursor
                                        $selected[$absIdx] = -not $selected[$absIdx]
                                        Enforce-ReviewMutex $absIdx
                                    }
                                }
                                ([ConsoleKey]::Escape)   { $inSub = $false }
                                ([ConsoleKey]::LeftArrow) { $inSub = $false }
                                default {
                                    switch ($subKey.KeyChar) {
                                        'a' { for ($j = $groupStart[$subG]; $j -le $groupEnd[$subG]; $j++) { $selected[$j] = $true }; if ($subG -eq 2) { for ($j = $groupStart[2]; $j -le $groupEnd[2]; $j++) { if ($allItems[$j].Id -eq "review-codex") { $selected[$j] = $false } } } }
                                        'n' { for ($j = $groupStart[$subG]; $j -le $groupEnd[$subG]; $j++) { $selected[$j] = $false } }
                                        'd' { for ($j = $groupStart[$subG]; $j -le $groupEnd[$subG]; $j++) { $selected[$j] = $allItems[$j].Default } }
                                        'q' { $inSub = $false }
                                        'j' { if ($subCursor -lt $subN) { $subCursor++ } }
                                        'k' { if ($subCursor -gt 0) { $subCursor-- } }
                                    }
                                }
                            }
                        }
                    }
                }
                default {
                    switch ($key.KeyChar) {
                        'a' { for ($i = 0; $i -lt $n; $i++) { $selected[$i] = $true }; for ($j = $groupStart[2]; $j -le $groupEnd[2]; $j++) { if ($allItems[$j].Id -eq "review-codex") { $selected[$j] = $false } } }
                        'n' { for ($i = 0; $i -lt $n; $i++) { $selected[$i] = $false } }
                        'd' { for ($i = 0; $i -lt $n; $i++) { $selected[$i] = $allItems[$i].Default } }
                        'q' { [Console]::CursorVisible = $savedCursorVisible; Write-Host ""; Write-Info "Cancelled."; exit 0 }
                        'j' { if ($cursor -lt $submitIndex) { $cursor++ } }
                        'k' { if ($cursor -gt 0) { $cursor-- } }
                    }
                }
            }
        }
    } finally {
        [Console]::CursorVisible = $savedCursorVisible
    }

    # Plugin ID -> package mapping
    $pluginMap = @{
        "plug-andrej-karpathy-skills" = "andrej-karpathy-skills@karpathy-skills"
        "plug-everything-claude-code" = "ecc@ecc"
        "plug-superpowers" = "superpowers@claude-plugins-official"
        "plug-frontend-slides" = "frontend-slides@frontend-slides"
        "plug-ppt-master" = "ppt-master@ppt-master"
        "plug-context7" = "context7@claude-plugins-official"
        "plug-commit-commands" = "commit-commands@claude-plugins-official"
        "plug-document-skills" = "document-skills@anthropic-agent-skills"
        "plug-playwright" = "playwright@claude-plugins-official"
        "plug-feature-dev" = "feature-dev@claude-plugins-official"
        "plug-code-simplifier" = "code-simplifier@claude-plugins-official"
        "plug-ralph-loop" = "ralph-loop@claude-plugins-official"
        "plug-example-skills" = "example-skills@anthropic-agent-skills"
        "plug-github" = "github@claude-plugins-official"
        "plug-claude-mem" = "claude-mem@thedotmack"
        "plug-pua" = "pua@pua-skills"
        "plug-tokenization" = "tokenization@ai-research-skills"
        "plug-fine-tuning" = "fine-tuning@ai-research-skills"
        "plug-post-training" = "post-training@ai-research-skills"
        "plug-inference-serving" = "inference-serving@ai-research-skills"
        "plug-distributed-training" = "distributed-training@ai-research-skills"
        "plug-optimization" = "optimization@ai-research-skills"
        "review-code-review" = "code-review@claude-plugins-official"
    }

    # Map selections to return value
    $result = @{
        ClaudeMd           = $false
        Settings           = $false
        Rules              = $false
        RuleLangs          = @()
        RuleLangsExplicit  = $true
        Hooks              = $false
        Lessons            = $false
        Skills             = $false
        SelectedSkills     = @()
        Agents             = $false
        Plugins            = $false
        SelectedPlugins    = @()
        PluginGroups       = @()
        Mcp                = $false
        Lark               = $false
        DeepXiv            = $false
        DeepXivSkills      = @()
        ReviewAdversarial  = $false
        ReviewCodex        = $false
        ReviewCodeReview   = $false
    }

    for ($i = 0; $i -lt $n; $i++) {
        if (-not $selected[$i]) { continue }
        $id = $allItems[$i].Id

        switch -Wildcard ($id) {
            "claude-md"          { $result.ClaudeMd = $true }
            "settings"           { $result.Settings = $true }
            "rules-common"       { $result.Rules = $true }
            "hooks"              { $result.Hooks = $true }
            "lessons"            { $result.Lessons = $true }
            "agents"             { $result.Agents = $true }
            "rules-python"       { $result.Rules = $true; $result.RuleLangs += "python" }
            "rules-ts"           { $result.Rules = $true; $result.RuleLangs += "typescript" }
            "rules-go"           { $result.Rules = $true; $result.RuleLangs += "golang" }
            "review-code-review" { $result.ReviewCodeReview = $true; $result.Plugins = $true; $result.SelectedPlugins += "code-review@claude-plugins-official" }
            "review-adversarial" { $result.ReviewAdversarial = $true; $result.Skills = $true; $result.SelectedSkills += "adversarial-review" }
            "review-codex"       { $result.ReviewCodex = $true; $result.Plugins = $true; $result.SelectedPlugins += "codex@openai-codex" }
            "skill-paper-reading"  { $result.Skills = $true; $result.SelectedSkills += "paper-reading" }
            "skill-cheatsheet-creator" { $result.Skills = $true; $result.SelectedSkills += "cheatsheet-creator" }
            "skill-humanizer"      { $result.Skills = $true; $result.SelectedSkills += "humanizer" }
            "skill-humanizer-zh"   { $result.Skills = $true; $result.SelectedSkills += "humanizer-zh" }
            "skill-update-config"  { $result.Skills = $true; $result.SelectedSkills += "update-config" }
            "deepxiv-cli"          { $result.DeepXiv = $true; $result.DeepXivSkills += "deepxiv-cli" }
            "deepxiv-trending-digest" { $result.DeepXiv = $true; $result.DeepXivSkills += "deepxiv-trending-digest" }
            "deepxiv-baseline-table"  { $result.DeepXiv = $true; $result.DeepXivSkills += "deepxiv-baseline-table" }
            "mcp"                { $result.Mcp = $true }
            "mcp-lark"           { $result.Lark = $true }
            "plug-*"             {
                $result.Plugins = $true
                if ($pluginMap.ContainsKey($id)) { $result.SelectedPlugins += $pluginMap[$id] }
            }
        }
    }

    return $result
}

# --- Install functions -----------------------------------------------------

function Install-ClaudeMd {
    param([bool]$ReviewAdversarial = $false, [bool]$ReviewCodex = $false)
    Write-Info "Installing CLAUDE.md..."

    # Dynamic Code Review section
    if ($ReviewAdversarial) {
        $reviewLine = 'Whenever a code review is needed — whether explicitly requested by the user or triggered by a skill (e.g., `code-reviewer`, `simplify`) — always invoke the `adversarial-review` skill to perform it. If the adversarial-review skill is unavailable (e.g., `codex` CLI not installed), fall back to using the `code-reviewer` agent for the review. Never substitute the actual review call with a text-only description.'
    } elseif ($ReviewCodex) {
        $reviewLine = 'Whenever a code review is needed — whether explicitly requested by the user or triggered by a skill (e.g., `code-reviewer`, `simplify`) — first check if the Codex plugin is available by running `/codex:setup`. If Codex is ready (`ready: true`), invoke `/codex:adversarial-review` to perform the review. If Codex is unavailable or not authenticated, fall back to using the `code-reviewer` agent for the review. Never substitute the actual review call with a text-only description.'
    } else {
        $reviewLine = 'Whenever a code review is needed — whether explicitly requested by the user or triggered by a skill (e.g., `code-reviewer`, `simplify`) — use the `code-reviewer` agent to perform it. Never substitute the actual review call with a text-only description.'
    }

    if ($DryRun) {
        Write-Info "Would copy: CLAUDE.md -> $CLAUDE_DIR\CLAUDE.md"
        Write-Info "  Code Review: adversarial=$ReviewAdversarial codex=$ReviewCodex"
    } else {
        $target = Join-Path $CLAUDE_DIR "CLAUDE.md"

        # Build the target content in a temp file (with the review line replaced)
        $tmpFile = Join-Path ([System.IO.Path]::GetTempPath()) "CLAUDE_md_$(Get-Random)"
        Copy-Item (Join-Path $SCRIPT_DIR "CLAUDE.md") $tmpFile -Force
        $content = Get-Content $tmpFile -Raw
        $content = $content -replace '(?m)^Whenever a code review is needed.*$', $reviewLine
        Set-Content $tmpFile $content -NoNewline

        # Compare with existing — skip if identical
        if ((Test-Path $target) -and ((Get-FileHash $target).Hash -eq (Get-FileHash $tmpFile).Hash)) {
            Write-Ok "CLAUDE.md unchanged, skipping"
            Remove-Item $tmpFile -Force
            return
        }

        # Content differs: back up existing before overwriting
        if (Test-Path $target) {
            Copy-Item $target "$target.bak" -Force
            Write-Warn "Existing CLAUDE.md backed up to CLAUDE.md.bak — merge your customizations manually"
        }
        Move-Item $tmpFile $target -Force
        Write-Ok "CLAUDE.md installed"
    }
}

function Get-EffectiveSelectedPlugins {
    param(
        [string[]]$SelectedPluginsList = @(),
        [string[]]$Groups = @()
    )
    $pkgs = @()
    if ($SelectedPluginsList.Count -gt 0) { $pkgs += $SelectedPluginsList }
    foreach ($g in $Groups) {
        switch ($g) {
            "essential" { $pkgs += $PLUGINS_ESSENTIAL }
            "claude-mem" { $pkgs += $PLUGINS_CLAUDE_MEM }
            "ai-research" { $pkgs += $PLUGINS_AI_RESEARCH }
            "pua" { $pkgs += $PLUGINS_PUA }
            "all" { $pkgs += $PLUGINS_ESSENTIAL + $PLUGINS_OPTIONAL + $PLUGINS_CLAUDE_MEM + $PLUGINS_AI_RESEARCH + $PLUGINS_PUA }
        }
    }
    return @($pkgs | Select-Object -Unique)
}

function Install-Settings {
    param(
        [bool]$InstallPlugins = $false,
        [string[]]$SelectedPluginsList = @(),
        [string[]]$PluginGroups = @()
    )
    Write-Info "Installing settings.json..."
    $target = Join-Path $CLAUDE_DIR "settings.json"
    $source = Join-Path $SCRIPT_DIR "settings.json"

    $effectiveSelected = @()
    if ($InstallPlugins) {
        $effectiveSelected = Get-EffectiveSelectedPlugins -SelectedPluginsList $SelectedPluginsList -Groups $PluginGroups
    }
    $selSet = @{}
    foreach ($p in $effectiveSelected) { $selSet[$p] = $true }

    if (-not (Test-Path $target)) {
        if ($DryRun) {
            Write-Info "Would copy: settings.json -> $target"
        } else {
            Copy-Item $source $target -Force
            if ($InstallPlugins) {
                try {
                    Set-StrictMode -Off
                    $obj = Get-Content $target -Raw | ConvertFrom-Json
                    # Fresh install: catalogue = source keys ∪ selection so plugins
                    # picked in the menu that aren't declared in the shipped
                    # settings.json (codex, health, pua) still land as true.
                    $filtered = [ordered]@{}
                    $seen = @{}
                    if ($obj.enabledPlugins) {
                        foreach ($prop in $obj.enabledPlugins.PSObject.Properties) {
                            $filtered[$prop.Name] = [bool]$selSet[$prop.Name]
                            $seen[$prop.Name] = $true
                        }
                    }
                    foreach ($k in $selSet.Keys) {
                        if (-not $seen.ContainsKey($k)) { $filtered[$k] = $true }
                    }
                    $obj.enabledPlugins = [PSCustomObject]$filtered
                    $obj | ConvertTo-Json -Depth 10 | Set-Content $target -Encoding UTF8
                    Set-StrictMode -Version Latest
                } catch {
                    Set-StrictMode -Version Latest
                    Write-Warn "Could not apply plugin selection filter: $_"
                }
            }
            Write-Ok "settings.json installed (new)"
        }
        return
    }

    # Smart merge using PowerShell JSON
    if ($DryRun) {
        Write-Info "Would smart-merge settings.json"
        Write-Info "  - env: incoming as defaults, existing overrides"
        Write-Info "  - permissions.allow: union of arrays"
        if ($InstallPlugins) {
            Write-Info "  - enabledPlugins: selection-aware rebuild (unselected known plugins disabled, unknown plugins preserved)"
        } else {
            Write-Info "  - enabledPlugins: union (existing preserved on conflict)"
        }
        Write-Info "  - hooks.SessionStart: deduplicated by matcher"
        Write-Info "  - statusLine: incoming takes priority"
        return
    }

    # Validate existing settings.json before merge
    try {
        Get-Content $target -Raw | ConvertFrom-Json | Out-Null
    } catch {
        Write-Err "Existing settings.json is not valid JSON — cannot merge safely"
        Write-Err "  Fix the file manually: $target"
        Copy-Item $target "$target.broken" -Force
        Write-Warn "Broken file backed up to settings.json.broken"
        $script:InstallCritical++
        return
    }

    try {
        # Relax strict mode for dynamic JSON property access
        Set-StrictMode -Off

        $existing = Get-Content $target -Raw | ConvertFrom-Json
        $incoming = Get-Content $source -Raw | ConvertFrom-Json

        # Helper: convert PSCustomObject to ordered hashtable
        $toHt = {
            param($obj)
            if ($null -eq $obj) { return [ordered]@{} }
            if ($obj -is [System.Collections.IDictionary]) { return $obj }
            $ht = [ordered]@{}
            $obj.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
            return $ht
        }

        # Helper: merge two objects as hashtables (second wins on conflict)
        $mergeHt = {
            param($base, $over)
            $result = [ordered]@{}
            $b = & $toHt $base
            $o = & $toHt $over
            foreach ($key in $b.Keys) { $result[$key] = $b[$key] }
            foreach ($key in $o.Keys) { $result[$key] = $o[$key] }
            return $result
        }

        # env: incoming as defaults, existing overrides
        $mergedEnv = & $mergeHt $incoming.env $existing.env

        # permissions.allow: union
        $baseAllow = if ($incoming.permissions -and $incoming.permissions.allow) { @($incoming.permissions.allow) } else { @() }
        $overAllow = if ($existing.permissions -and $existing.permissions.allow) { @($existing.permissions.allow) } else { @() }
        $mergedAllow = @($baseAllow + $overAllow | Select-Object -Unique)

        # enabledPlugins: if plugins were interacted with this run, apply the selection
        # filter to the catalogue (source keys ∪ selected keys — so plugins picked in
        # the menu that aren't declared in the shipped settings.json, e.g. codex,
        # health, pua, still land as true). User-added keys that exist only in
        # $existing (outside our catalogue) are preserved verbatim so the installer
        # never silently disables third-party plugins.
        # If plugins were not interacted with, fall back to union merge with existing
        # winning on conflict (per the documented promise).
        if ($InstallPlugins) {
            $mergedPlugins = [ordered]@{}
            $catalogueKeys = @{}
            if ($incoming.enabledPlugins) {
                foreach ($prop in $incoming.enabledPlugins.PSObject.Properties) {
                    $catalogueKeys[$prop.Name] = $true
                }
            }
            foreach ($k in $selSet.Keys) { $catalogueKeys[$k] = $true }
            foreach ($k in $catalogueKeys.Keys) {
                $mergedPlugins[$k] = [bool]$selSet[$k]
            }
            if ($existing.enabledPlugins) {
                foreach ($prop in $existing.enabledPlugins.PSObject.Properties) {
                    if (-not $catalogueKeys.ContainsKey($prop.Name)) {
                        $mergedPlugins[$prop.Name] = $prop.Value
                    }
                }
            }
        } else {
            # Swapped order: $incoming first, $existing second → existing wins on conflict.
            $mergedPlugins = & $mergeHt $incoming.enabledPlugins $existing.enabledPlugins
        }

        # Strip tombstoned (removed) plugins so they don't linger enabled after upgrade.
        foreach ($r in $PLUGINS_REMOVED) { if ($mergedPlugins.Contains($r)) { [void]$mergedPlugins.Remove($r) } }

        # hooks.SessionStart: deduplicate by matcher (last wins)
        $sessionHooks = [ordered]@{}
        if ($incoming.hooks -and $incoming.hooks.SessionStart) {
            foreach ($h in @($incoming.hooks.SessionStart)) { if ($h.matcher) { $sessionHooks[$h.matcher] = $h } }
        }
        if ($existing.hooks -and $existing.hooks.SessionStart) {
            foreach ($h in @($existing.hooks.SessionStart)) { if ($h.matcher) { $sessionHooks[$h.matcher] = $h } }
        }
        $mergedSessionHooks = @($sessionHooks.Values)

        # Build merged result as hashtable (avoids PSCustomObject assignment issues)
        $merged = & $mergeHt $incoming $existing

        # Override with merged fields
        $merged["env"] = [PSCustomObject]$mergedEnv
        $merged["enabledPlugins"] = [PSCustomObject]$mergedPlugins
        $merged["statusLine"] = $incoming.statusLine
        $mergedPerms = & $mergeHt $incoming.permissions $existing.permissions
        $mergedPerms["allow"] = $mergedAllow
        $merged["permissions"] = [PSCustomObject]$mergedPerms
        $mergedHooks = & $mergeHt $incoming.hooks $existing.hooks
        $mergedHooks["SessionStart"] = $mergedSessionHooks
        $merged["hooks"] = [PSCustomObject]$mergedHooks

        [PSCustomObject]$merged | ConvertTo-Json -Depth 10 | Set-Content $target -Encoding UTF8

        Set-StrictMode -Version Latest
        Write-Ok "settings.json smart-merged"
    } catch {
        Set-StrictMode -Version Latest
        Write-Err "Merge failed: $_"
        Write-Warn "Please merge manually: $source -> $target"
        $script:InstallCritical++
    }
}

function Install-Rules {
    param(
        [string[]]$Langs = @(),
        [bool]$LangsExplicit = $false
    )

    Write-Info "Installing rules..."
    $rulesDir = Join-Path $CLAUDE_DIR "rules"
    if (-not $DryRun) { New-Item -ItemType Directory -Path $rulesDir -Force | Out-Null }

    # Always install common rules
    $commonSrc = Join-Path $SCRIPT_DIR "rules\common"
    $commonDst = Join-Path $rulesDir "common"
    if ($DryRun) {
        Write-Info "Would copy: rules\common\ -> $commonDst"
    } else {
        if (Test-Path $commonDst) { Remove-Item $commonDst -Recurse -Force }
        Copy-Item $commonSrc $commonDst -Recurse -Force
        Write-Ok "Common rules installed"
    }

    # Determine languages
    $installLangs = @()
    if ($Langs.Count -gt 0) {
        $installLangs = $Langs
    } elseif (-not $LangsExplicit) {
        # Auto-detect: install all available languages (--all mode)
        Get-ChildItem (Join-Path $SCRIPT_DIR "rules") -Directory | ForEach-Object {
            if ($_.Name -ne "common") { $installLangs += $_.Name }
        }
    }
    # If LangsExplicit=true and Langs is empty, skip language rules

    foreach ($lang in $installLangs) {
        $langSrc = Join-Path $SCRIPT_DIR "rules\$lang"
        if (Test-Path $langSrc) {
            $langDst = Join-Path $rulesDir $lang
            if ($DryRun) {
                Write-Info "Would copy: rules\$lang\ -> $langDst"
            } else {
                if (Test-Path $langDst) { Remove-Item $langDst -Recurse -Force }
                Copy-Item $langSrc $langDst -Recurse -Force
                Write-Ok "$lang rules installed"
            }
        } else {
            Write-Err "Language rules not found: $lang"
        }
    }

    # Clean up known language rule dirs that were NOT selected (from previous installs)
    # Only removes languages this installer knows about; preserves user-created dirs
    if ($LangsExplicit) {
        $knownLangs = @("python", "typescript", "golang")
        foreach ($known in $knownLangs) {
            if ($installLangs -notcontains $known) {
                $langDir = Join-Path $rulesDir $known
                if (Test-Path $langDir) {
                    if ($DryRun) {
                        Write-Info "Would remove unselected: $langDir"
                    } else {
                        Remove-Item $langDir -Recurse -Force
                        Write-Ok "Removed unselected rules: $known"
                    }
                }
            }
        }
    }

    $readmeSrc = Join-Path $SCRIPT_DIR "rules\README.md"
    if (Test-Path $readmeSrc) {
        if ($DryRun) {
            Write-Info "Would copy: rules\README.md -> $rulesDir\README.md"
        } else {
            Copy-Item $readmeSrc (Join-Path $rulesDir "README.md") -Force
        }
    }
}

function Install-Skills {
    param([string[]]$SelectedSkills = @())
    Write-Info "Installing custom skills..."
    $skillsDir = Join-Path $CLAUDE_DIR "skills"
    if (-not $DryRun) { New-Item -ItemType Directory -Path $skillsDir -Force | Out-Null }

    # Migration removes only explicitly provenance-backed retired content.
    foreach ($oldSkill in @("update")) {
        $oldPath = Join-Path $skillsDir $oldSkill
        if (Test-Path $oldPath) {
            if ($DryRun) {
                Write-Info "Would remove legacy skill: $oldSkill"
            } else {
                Remove-Item $oldPath -Recurse -Force
                Write-Ok "Removed legacy skill: $oldSkill"
            }
        }
    }

    if ($SelectedSkills.Count -gt 0) {
        # Install only selected skills
        foreach ($skill in $SelectedSkills) {
            $src = Join-Path (Join-Path $SCRIPT_DIR "skills") $skill
            $dst = Join-Path $skillsDir $skill
            if (Test-Path $src) {
                if ($DryRun) {
                    Write-Info "Would copy: skills\$skill\ -> $dst"
                } else {
                    if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
                    Copy-Item $src $dst -Recurse -Force
                    Write-Ok "Skill installed: $skill"
                }
            } else {
                Write-Warn "Skill not found: $skill"
            }
        }
    } else {
        # --All mode: install everything
        Get-ChildItem (Join-Path $SCRIPT_DIR "skills") -Directory | ForEach-Object {
            $skill = $_.Name
            $dst = Join-Path $skillsDir $skill
            if ($DryRun) {
                Write-Info "Would copy: skills\$skill\ -> $dst"
            } else {
                if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
                Copy-Item $_.FullName $dst -Recurse -Force
                Write-Ok "Skill installed: $skill"
            }
        }
    }

    # Clean up installer-managed skills that were NOT selected (from previous installs)
    # Only runs in interactive mode where specific skills were selected
    if ($SelectedSkills.Count -gt 0) {
        $repoSkillsDir = Join-Path $SCRIPT_DIR "skills"
        if (Test-Path $repoSkillsDir) {
            Get-ChildItem $repoSkillsDir -Directory | ForEach-Object {
                $known = $_.Name
                $keep = $false
                foreach ($skill in $SelectedSkills) {
                    if ($skill -eq $known) { $keep = $true; break }
                }
                if (-not $keep) {
                    $removePath = Join-Path $skillsDir $known
                    if (Test-Path $removePath) {
                        if ($DryRun) {
                            Write-Info "Would remove unselected skill: $known"
                        } else {
                            Remove-Item $removePath -Recurse -Force
                            Write-Ok "Removed unselected skill: $known"
                        }
                    }
                }
            }
        }
    }
}

function Install-Agents {
    Write-Info "Installing custom agents..."
    $agentDir = Join-Path $CLAUDE_DIR "agents"
    if (-not $DryRun -and -not (Test-Path $agentDir)) { New-Item -ItemType Directory -Path $agentDir -Force | Out-Null }
    Get-ChildItem (Join-Path $SCRIPT_DIR "agents") -Filter "*.md" | ForEach-Object {
        if ($DryRun) {
            Write-Info "Would copy: agents/$($_.Name) -> $agentDir\$($_.Name)"
        } else {
            Copy-Item $_.FullName (Join-Path $agentDir $_.Name) -Force
            Write-Ok "Agent installed: $($_.Name)"
        }
    }
}

# image-gen-cliproxyapi.sh is the always-installed CLIProxyAPI delegation wrapper
# consumed by the network-installed sinedied/agent-skills:image-gen Skill (see
# Install-ImageGen). Installed as a user script so uninstall removes it. It is a
# Bash script; native Windows cl_*/CLIProxyAPI service lifecycle is unsupported.
$USER_SCRIPTS = @("cleanup-claude-data.sh", "image-gen-cliproxyapi.sh")

function Install-Scripts {
    Write-Info "Installing maintenance scripts..."
    $srcDir = Join-Path $SCRIPT_DIR "scripts"
    if (-not (Test-Path $srcDir)) { Write-Info "No scripts/ directory in source, skipping"; return }
    $destDir = Join-Path $CLAUDE_DIR "scripts"
    # DryRun writes nothing — no directory creation (keeps USERPROFILE side-effect-free).
    if (-not $DryRun -and -not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    foreach ($script in $USER_SCRIPTS) {
        $src = Join-Path $srcDir $script
        if (-not (Test-Path $src)) { Write-Warn "Expected script missing in source: $script"; continue }
        if ($DryRun) {
            Write-Info "Would copy: scripts/$script -> $destDir\$script"
        } else {
            Copy-Item $src (Join-Path $destDir $script) -Force
            Write-Ok "Script installed: $script (run manually; not auto-executed)"
        }
    }
}

# Run the installed data-cleanup script. Mirrors run_cleanup() in install.sh.
# The cleanup script is bash (cleanup-claude-data.sh), so on Windows it needs a
# bash interpreter (Git Bash or WSL); if none is available it is skipped with a
# warning rather than failing the install. In DryRun the cleanup runs its own
# (non-deleting) dry-run report.
function Invoke-Cleanup {
    $script = Join-Path $CLAUDE_DIR "scripts\cleanup-claude-data.sh"
    if (-not (Test-Path $script)) {
        Write-Info "Cleanup script not installed; skipping data cleanup"
        return
    }
    if (-not (Get-Command bash -ErrorAction SilentlyContinue)) {
        Write-Warn "bash not found - skipping data cleanup (install Git Bash or WSL, or run scripts\cleanup-claude-data.sh manually)"
        return
    }
    if ($DryRun) {
        Write-Info "Would run data cleanup (dry-run report):"
        if (Test-Path $CLAUDE_DIR) {
            & bash "$script"
        } else {
            Write-Info "  (skipped report - $CLAUDE_DIR does not exist yet)"
        }
        return
    }
    Write-Info "Running Claude data cleanup (--apply)..."
    & bash "$script" --apply
    if ($LASTEXITCODE -ne 0) { Write-Warn "Data cleanup reported a non-fatal error" }
}

# ============================================================
# image-gen (sinedied/agent-skills) always-installed network Skill.
# PowerShell parity with install.sh install_image_gen.
#
# The upstream Skill is fetched with the same `skills` CLI as
# mattpocock/skills — never vendored. After a successful download the
# installer augments the downloaded SKILL.md with an idempotent managed
# instructions block pointing Claude Code at the repository-owned wrapper,
# then writes an ownership manifest so uninstall deletes only an
# installer-owned image-gen directory (never a user-authored one).
#
# Always installed: no selectable flag, no menu item. Missing npx or a
# failed download is non-fatal — it increments $script:InstallWarnings so
# the summary surfaces it while letting the rest of the install finish.
#
# IMPORTANT: the wrapper asset (image-gen-cliproxyapi.sh) is a Bash script.
# Native Windows cl_*/CLIProxyAPI service lifecycle is NOT supported; the
# wrapper is installed for WSL / Git-Bash / Bash-compatible environments.
# ============================================================

# Managed markers wrapping the integration block in the installed SKILL.md.
$IMAGE_GEN_BEGIN_MARKER = "<!-- BEGIN claude-code-config CLIProxyAPI image-gen integration -->"
$IMAGE_GEN_END_MARKER = "<!-- END claude-code-config CLIProxyAPI image-gen integration -->"

# Exact canonical ownership manifest content. Validation compares
# byte-for-byte (order, one trailing newline, no extras/CRLF). Kept as a
# single literal so it is the only source of truth.
$IMAGE_GEN_MANIFEST_CANONICAL = "skill=image-gen`nsource=sinedied/agent-skills`nwrapper=image-gen-cliproxyapi.sh"

# Returns the exact `skills add` argument array. Installs globally to
# ~/.claude/skills/ as real copies for Claude Code, scoped to the single
# image-gen Skill. Pure: returns an array, no side effects.
function Get-ImageGenNpxArgs {
    return @(
        "-y", "skills@latest", "add", "sinedied/agent-skills",
        "--global", "--agent", "claude-code", "--copy", "--yes",
        "--skill", "image-gen"
    )
}

# Returns the canonical managed instructions block (the bytes between the
# markers). Pure: no side effects. Tells Claude Code to invoke the wrapper,
# forward upstream arguments, avoid requesting an OpenAI Platform API key,
# and notes the loopback endpoint, model, and the native-Windows limitation.
# Single-quoted here-string: literal (no `$ expansion, no backtick escapes).
function Get-ImageGenIntegrationBlock {
    return @'
Run image generation through the local CLIProxyAPI wrapper instead of invoking
`image_gen.py` directly or requesting an OpenAI Platform API key:

    ~/.claude/scripts/image-gen-cliproxyapi.sh <upstream arguments>

Forward all upstream arguments (`generate`, `edit`, prompts, file paths, and
image options) unchanged. The wrapper starts or reuses CLIProxyAPI on the
loopback endpoint `http://127.0.0.1:8317/v1`, reads the local client key
without exposing it, and requests the `gpt-image-2` model. Do not ask the user
for an OpenAI Platform API key — image generation is covered by the local
CLIProxyAPI using ChatGPT/Codex OAuth.

Note: native Windows `cl_*`/CLIProxyAPI service lifecycle is not supported.
The wrapper is a Bash script — run it inside WSL (run the Bash installer inside
WSL so it lands in the WSL `~/.claude`, NOT the Windows `%USERPROFILE%\.claude`,
which WSL does not see as `~/.claude`). Git Bash may also work but its
`~/.claude` -> `%USERPROFILE%\.claude` mapping depends on the install, so WSL
is the recommended path for a faithful `~/.claude` layout.
'@
}

# Strict marker-layout validator. Single source of truth for "does this
# SKILL.md have a well-formed managed block?" Returns $true iff the file has
# exactly one exact-line BEGIN, exactly one exact-line END, BEGIN precedes
# END, and no line carries marker text without being an exact marker line
# (embedded prose), with no duplicates, nesting, or unterminated state.
# Ownership and augmentation both consult this so a hand-edited or hostile
# SKILL.md can never authorize deletion or overwrite.
function Test-ImageGenMarkersStrict {
    param([Parameter(Mandatory=$true)][string]$SkillMd)
    if (-not (Test-Path -LiteralPath $SkillMd)) { return $false }
    $lines = @(Get-Content -LiteralPath $SkillMd -ErrorAction SilentlyContinue)
    $begin = 0; $end = 0; $inBlock = $false; $bad = $false; $embedded = $false
    foreach ($line in $lines) {
        if ($line -ceq $IMAGE_GEN_BEGIN_MARKER) {
            if ($inBlock) { $bad = $true }
            if ($end -gt 0) { $bad = $true }
            $begin++
            if ($begin -gt 1) { $bad = $true }
            $inBlock = $true
        } elseif ($line -ceq $IMAGE_GEN_END_MARKER) {
            if (-not $inBlock) { $bad = $true }
            $end++
            if ($end -gt 1) { $bad = $true }
            $inBlock = $false
        } elseif ($line.Contains($IMAGE_GEN_BEGIN_MARKER) -or $line.Contains($IMAGE_GEN_END_MARKER)) {
            $embedded = $true
        }
    }
    if ($bad -or $embedded) { return $false }
    return ($begin -eq 1 -and $end -eq 1)
}

# Validate that an image-gen ownership manifest is byte-for-byte identical to
# the canonical content this installer writes: exactly three lines in order,
# one trailing newline, no duplicates/extras, no CRLF. Byte comparison so a
# field-by-field parser cannot accept reordering/duplication. Pure.
function Test-ImageGenManifestValid {
    param([Parameter(Mandatory=$true)][string]$Manifest)
    if (-not (Test-Path -LiteralPath $Manifest)) { return $false }
    try {
        $actual = [System.IO.File]::ReadAllBytes($Manifest)
    } catch { return $false }
    $expected = [System.Text.Encoding]::UTF8.GetBytes($IMAGE_GEN_MANIFEST_CANONICAL + "`n")
    if ($actual.Length -ne $expected.Length) { return $false }
    for ($i = 0; $i -lt $actual.Length; $i++) {
        if ($actual[$i] -ne $expected[$i]) { return $false }
    }
    return $true
}

# Full ownership proof: a directory is installer-owned ONLY when a valid
# manifest exists AND the installed SKILL.md passes the strict marker
# validator. A completed install always writes markers before the manifest,
# so a user-created directory with a planted valid manifest but malformed or
# absent markers is treated as unowned and never mutated or deleted.
function Test-ImageGenDirOwned {
    param(
        [Parameter(Mandatory=$true)][string]$SkillDir,
        [Parameter(Mandatory=$true)][string]$Manifest
    )
    if (-not (Test-Path -LiteralPath $SkillDir)) { return $false }
    if (-not (Test-ImageGenManifestValid -Manifest $Manifest)) { return $false }
    return (Test-ImageGenMarkersStrict -SkillMd (Join-Path $SkillDir "SKILL.md"))
}

# Write the ownership manifest atomically. The manifest is the sole authority
# uninstall uses. Written with explicit LF + one trailing newline so the byte
# comparison in Test-ImageGenManifestValid holds. Atomicity:
#   - Existing destination: [System.IO.File]::Replace swaps old<->new in one
#     same-volume operation (the prior bytes go to a backup file we remove).
#     On ANY Replace failure the old manifest is preserved byte-for-byte and
#     the temp/backup are cleaned; there is NO Move-Item fallback over an
#     existing destination (a rename-over is not a guaranteed atomic swap and
#     has a delete window).
#   - First install (no destination): same-dir temp + Move-Item (rename), no
#     delete-first window.
#   - Any failure returns $false and keeps the old manifest.
function Write-ImageGenManifest {
    param([Parameter(Mandatory=$true)][string]$Manifest)
    $dir = Split-Path -Parent $Manifest
    if (-not (Test-Path $dir)) { return $false }
    $leaf = Split-Path -Leaf $Manifest
    $tmp = Join-Path $dir ("." + $leaf + "." + (Get-Random) + ".tmp")
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($IMAGE_GEN_MANIFEST_CANONICAL + "`n")
    try {
        [System.IO.File]::WriteAllBytes($tmp, $bytes)
    } catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        return $false
    }
    if (Test-Path -LiteralPath $Manifest) {
        # Atomic same-volume Replace; backup holds prior bytes until we delete it.
        # On failure: preserve old manifest, clean temp + backup, return $false.
        $bak = Join-Path $dir ("." + $leaf + "." + (Get-Random) + ".bak")
        try {
            [System.IO.File]::Replace($tmp, $Manifest, $bak)
        } catch {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue }
            return $false
        }
        Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue
    } else {
        # First install: rename into place (no delete-first).
        try {
            Move-Item -LiteralPath $tmp -Destination $Manifest -Force
        } catch {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
            return $false
        }
    }
    return $true
}

# Idempotently augment the installed image-gen SKILL.md with the managed
# integration block. TRUE BYTE-OFFSET SPLICE: never UTF-8 decodes/re-encodes the
# whole file (which would corrupt malformed UTF-8). Instead it reads raw bytes,
# decodes via the byte-preserving ISO-8859-1 (Latin1) mapping SOLELY to locate
# ASCII marker lines (char index == byte offset), and emits the OUTSIDE bytes
# verbatim from the original byte array. The managed block bytes are generated
# as UTF-8 and joined with the file's detected newline. Preserves: UTF-8 BOM,
# CRLF/LF/CR newline style, the final-newline state, and EVERY byte outside the
# managed interval (including malformed UTF-8). Strict malformed-state rejection
# (embedded/duplicate/one-sided/reversed markers). Atomic same-dir temp +
# Move-Item -Force. Returns $true on success.
function Update-ImageGenSkillInstructions {
    param([string]$SkillsDir = (Join-Path $CLAUDE_DIR "skills"))
    $skillMd = Join-Path $SkillsDir "image-gen\SKILL.md"
    $upstream = Join-Path $SkillsDir "image-gen\image_gen.py"
    if (-not (Test-Path -LiteralPath $skillMd)) {
        Write-Warn "image-gen: SKILL.md not found at $skillMd - augmentation skipped"
        return $false
    }
    if (-not (Test-Path -LiteralPath $upstream)) {
        Write-Warn "image-gen: image_gen.py not found at $upstream - augmentation skipped"
        return $false
    }

    try { $all = [System.IO.File]::ReadAllBytes($skillMd) } catch {
        Write-Warn "image-gen: failed to read $skillMd - augmentation skipped"
        return $false
    }

    # Preserve a UTF-8 BOM (EF BB BF) if present; exclude from the body scan and
    # re-emit it verbatim on write.
    $bomLen = 0
    if ($all.Length -ge 3 -and $all[0] -eq 0xEF -and $all[1] -eq 0xBB -and $all[2] -eq 0xBF) { $bomLen = 3 }

    # Latin1 decode is byte-preserving (char index == byte offset) for ALL 256
    # byte values, so malformed UTF-8 outside the markers is never corrupted and
    # ASCII marker comparison is exact. We use this ONLY to find offsets; outside
    # bytes are emitted from the ORIGINAL byte array.
    $latin1 = [System.Text.Encoding]::GetEncoding("ISO-8859-1")
    $body = $latin1.GetString($all, $bomLen, $all.Length - $bomLen)

    # Detect the file's newline style from its raw bytes (UTF-8 continuation/
    # lead bytes never equal 0x0A/0x0D, so detection is unambiguous).
    $nlBytes = [byte[]](0x0A)
    for ($i = $bomLen; $i -lt $all.Length; $i++) {
        if ($all[$i] -eq 0x0D) {
            if (($i + 1) -lt $all.Length -and $all[$i + 1] -eq 0x0A) { $nlBytes = [byte[]](0x0D, 0x0A) }
            else { $nlBytes = [byte[]](0x0D) }
            break
        }
        if ($all[$i] -eq 0x0A) { $nlBytes = [byte[]](0x0A); break }
    }

    # Split into alternating (line-content, separator) segments so we can compute
    # byte offsets of each marker line. Markers are pure ASCII, so -ceq on the
    # Latin1 string is an exact byte comparison.
    $segs = [regex]::Split($body, '(\r\n|\r|\n)')
    $begin = $IMAGE_GEN_BEGIN_MARKER
    $end = $IMAGE_GEN_END_MARKER
    $beginContentIdx = -1; $endContentIdx = -1; $embedded = $false
    for ($i = 0; $i -lt $segs.Length; $i += 2) {
        $lc = $segs[$i]
        if ($lc -ceq $begin) {
            if ($beginContentIdx -ge 0) { $embedded = $true }
            $beginContentIdx = $i
        } elseif ($lc -ceq $end) {
            if ($endContentIdx -ge 0) { $embedded = $true }
            $endContentIdx = $i
        } elseif ($lc.Contains($begin) -or $lc.Contains($end)) {
            $embedded = $true
        }
    }
    if ($embedded) {
        Write-Warn "image-gen: SKILL.md markers malformed (embedded/duplicate) - augmentation skipped"
        return $false
    }

    # Build the managed block bytes: begin + nl + block + nl + end (UTF-8 for the
    # block, ASCII for markers; ASCII is a strict subset of UTF-8 so concat is
    # valid UTF-8). The block's INTERNAL newlines are normalized to the file's
    # detected target style (LF/CRLF/CR) so a CRLF file gets a CRLF block.
    $beginBytes = [System.Text.Encoding]::ASCII.GetBytes($begin)
    $endBytes = [System.Text.Encoding]::ASCII.GetBytes($end)
    $nlStr = if ($nlBytes.Length -eq 2) { "`r`n" } elseif ($nlBytes[0] -eq 0x0D) { "`r" } else { "`n" }
    $blockStr = Get-ImageGenIntegrationBlock
    # Normalize the block's internal newlines to the detected target style.
    $blockStr = $blockStr -replace "`r`n", "`n" -replace "`r", "`n"
    if ($nlStr -ne "`n") { $blockStr = $blockStr -replace "`n", $nlStr }
    $blockBytes = [System.Text.Encoding]::UTF8.GetBytes($blockStr)

    $ms = New-Object System.IO.MemoryStream
    # Helper to append a byte array.
    $append = [ScriptBlock]::Create('param([byte[]]$b) if ($b -and $b.Length) { $ms.Write($b, 0, $b.Length) }')

    if ($beginContentIdx -ge 0 -and $endContentIdx -ge 0 -and $beginContentIdx -lt $endContentIdx) {
        # REPLACE: head = everything before the begin marker line's content;
        # tail BEGINS at the original separator that followed the END marker
        # line (so that separator + all suffix bytes are preserved exactly).
        $headEnd = 0
        for ($i = 0; $i -lt $beginContentIdx; $i++) { $headEnd += $segs[$i].Length }
        # tailStart = offset of segs[endContentIdx+1] (the separator after end),
        # i.e. sum through endContentIdx inclusive. Preserves separator + suffix.
        $tailStart = 0
        for ($i = 0; $i -le $endContentIdx; $i++) { $tailStart += $segs[$i].Length }
        if ($bomLen -gt 0) { $ms.Write($all, 0, $bomLen) }
        & $append $latin1.GetBytes($body.Substring(0, $headEnd))
        & $append $beginBytes; & $append $nlBytes; & $append $blockBytes; & $append $nlBytes; & $append $endBytes
        if ($tailStart -lt $body.Length) { & $append $latin1.GetBytes($body.Substring($tailStart)) }
    } elseif ($beginContentIdx -lt 0 -and $endContentIdx -lt 0) {
        # APPEND: preserve the original final-newline state.
        # - Nonempty body WITHOUT a trailing newline: emit a separator before
        #   BEGIN (so BEGIN starts on its own line) and NO separator after END
        #   (the file ends at END, matching the original no-final-NL state).
        # - Terminated body (ends with newline): BEGIN starts on the next line
        #   (body's trailing separator is already present), and a trailing
        #   separator after END preserves the terminated state.
        $terminated = ($body.Length -gt 0) -and ($body -match '[\r\n]$')
        if ($bomLen -gt 0) { $ms.Write($all, 0, $bomLen) }
        & $append $latin1.GetBytes($body)
        if (-not $terminated -and $body.Length -gt 0) { & $append $nlBytes }
        & $append $beginBytes; & $append $nlBytes; & $append $blockBytes; & $append $nlBytes; & $append $endBytes
        if ($terminated) { & $append $nlBytes }
    } else {
        Write-Warn "image-gen: SKILL.md markers malformed (one-sided/unterminated) - augmentation skipped"
        return $false
    }
    $finalBytes = $ms.ToArray()

    # Atomic write: temp in the SAME directory, verify strict, then Move-Item.
    $tDir = Split-Path -Parent $skillMd
    $tLeaf = Split-Path -Leaf $skillMd
    $tmp = Join-Path $tDir ("." + $tLeaf + ".augment." + (Get-Random) + ".tmp")
    try {
        [System.IO.File]::WriteAllBytes($tmp, $finalBytes)
        if (-not (Test-ImageGenMarkersStrict -SkillMd $tmp)) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            Write-Warn "image-gen: augmentation produced malformed markers - skipped"
            return $false
        }
        Move-Item -LiteralPath $tmp -Destination $skillMd -Force
        return $true
    } catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        Write-Warn "image-gen: failed to write SKILL.md"
        return $false
    }
}

# Build the (FileName, Arguments) pair for invoking npx without relying on the
# `& npx` pipeline. Pure: no process start, no side effects — designed so a test
# can verify the exact command string for the Windows npx.cmd-under-spaced-path
# case. Uses the documented robust cmd.exe quoting: `cmd /d /s /c "<cmd>"` where
# /d disables registry AutoRun, /s strips the outer quote pair, and the inner
# command quotes the executable path. Every arg token is asserted whitespace-
# free (constant array, no shell expansion); returns $null on an unrepresentable
# token (fail closed).
function Get-ImageGenNpxCommandLine {
    param([Parameter(Mandatory=$true)][string]$Exe, [Parameter(Mandatory=$true)][string[]]$NpxArgs)
    foreach ($a in $NpxArgs) {
        if ($a -match '\s') { return $null }
    }
    if ($Exe -like '*.cmd') {
        # cmd.exe /d /s /c ""exe" arg1 arg2" — /s strips the outer pair, cmd then
        # sees "exe" arg1 arg2 (the exe path quoted, tolerating spaces).
        $argStr = '/d /s /c ""' + $Exe + '" ' + ($NpxArgs -join ' ') + '"'
        return @{ FileName = "cmd.exe"; Arguments = $argStr }
    } else {
        return @{ FileName = $Exe; Arguments = ($NpxArgs -join ' ') }
    }
}

# Invoke the npx skills command with a DETACHED stdin (immediate EOF so an
# interactive prompt can never block a non-interactive install), a CONSTANT
# argument array (no shell expansion; every token is asserted whitespace-free),
# and exit-code checking. Never relies on the `& npx` pipeline. Windows PS 5.1
# compatible; npx.cmd launched via the documented `cmd.exe /d /s /c` form.
# Drains stdout/stderr asynchronously to avoid pipe-buffer deadlock. Returns
# $true on exit code 0, $false otherwise (incl. unrepresentable tokens).
function Invoke-ImageGenNpx {
    param([Parameter(Mandatory=$true)][string[]]$NpxArgs)
    $npx = Get-Command npx -ErrorAction SilentlyContinue
    if (-not $npx) { return $false }
    $cli = Get-ImageGenNpxCommandLine -Exe $npx.Source -NpxArgs $NpxArgs
    if (-not $cli) { return $false }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $cli.FileName
    $psi.Arguments = $cli.Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    try {
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()
        # Close stdin immediately -> child sees EOF (null/detached stdin).
        $proc.StandardInput.Close()
        # Drain stdout/stderr asynchronously to avoid pipe-buffer deadlock when
        # npx emits progress output larger than the OS pipe buffer.
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $proc.WaitForExit()
        return ($proc.ExitCode -eq 0)
    } catch {
        return $false
    }
}

# Coordinator. Always-installed (no flag gate). Transactional upgrade:
#   - Prior valid ownership (manifest valid AND dir present): the prior skill
#     directory and manifest are backed up before npx mutation; on ANY later
#     failure both are restored so on-disk state is exactly the previous good
#     install.
#   - Unowned directory present (dir exists but not owned): NEVER overwritten.
#   - Fresh target (no dir): a stale/foreign manifest is removed first; on
#     failure after npx the half-installed directory is removed.
# Failure is non-fatal (increments $script:InstallWarnings, returns).
function Install-ImageGen {
    Write-Info "Installing image-gen Skill (sinedied/agent-skills, via npx skills)..."
    $skillDir = Join-Path $CLAUDE_DIR "skills\image-gen"
    $manifest = Join-Path $CLAUDE_DIR ".image-gen-sinedied"
    $npxArgs = Get-ImageGenNpxArgs
    $cmdPreview = "npx " + ($npxArgs -join " ")

    $priorOwned = Test-ImageGenDirOwned -SkillDir $skillDir -Manifest $manifest

    if ($DryRun) {
        Write-Info "Would run: `$env:DO_NOT_TRACK='1'; $cmdPreview"
        if ($priorOwned) { Write-Info "Would upgrade prior installer-owned image-gen (backed up first, restored on failure)" }
        Write-Info "Would augment $skillDir\SKILL.md with the managed integration block"
        Write-Info "Would write ownership manifest $manifest"
        return
    }

    # Reconcile stale ownership BEFORE every other early return: a valid
    # manifest with no skill directory is stale ownership of nothing; remove
    # it so it can never later authorize deletion of a user-created directory.
    if (-not $priorOwned -and (Test-Path -LiteralPath $manifest) -and (Test-ImageGenManifestValid -Manifest $manifest)) {
        Remove-Item -LiteralPath $manifest -Force -ErrorAction SilentlyContinue
        Write-Warn "image-gen: removed stale ownership manifest (no image-gen directory present)"
    }

    # npx availability check comes AFTER reconciliation so a missing-npx run
    # still cleans a stale manifest.
    if (-not (Get-Command npx -ErrorAction SilentlyContinue)) {
        Write-Warn "npx not found (needs Node.js) - skipping image-gen Skill (always-installed)."
        Write-Warn "  Install Node.js to get npx: https://nodejs.org"
        Write-Warn "  Then run: `$env:DO_NOT_TRACK='1'; $cmdPreview"
        $script:InstallWarnings++
        return
    }

    # Unowned directory protection: never overwrite a user-authored/foreign
    # directory that merely collides with the image-gen name.
    if ((Test-Path -LiteralPath $skillDir) -and -not $priorOwned) {
        Write-Warn "image-gen: $skillDir exists but is not installer-owned - skipping to avoid overwriting user content"
        Write-Warn "  To manage image-gen via this installer, remove the directory manually first, then re-run."
        $script:InstallWarnings++
        return
    }

    # Mandatory upgrade backup: for a prior-owned install, a verified backup
    # of skill + manifest must exist before npx; any failure aborts the
    # upgrade with prior bytes intact. Lives outside the skill directory.
    $backupDir = ""
    if ($priorOwned) {
        $backupDir = Join-Path ([System.IO.Path]::GetTempPath()) ("image-gen-prev." + (Get-Random))
        try {
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
            Copy-Item -LiteralPath $skillDir -Destination (Join-Path $backupDir "image-gen") -Recurse -Force
            Copy-Item -LiteralPath $manifest -Destination (Join-Path $backupDir "manifest") -Force
        } catch {
            Write-Warn "image-gen: failed to build upgrade backup - aborting upgrade (prior install left intact)"
            if ($backupDir -and (Test-Path $backupDir)) { Remove-Item $backupDir -Recurse -Force -ErrorAction SilentlyContinue }
            $script:InstallWarnings++
            return
        }
        if (-not (Test-Path (Join-Path $backupDir "manifest")) -or -not (Test-Path (Join-Path $backupDir "image-gen"))) {
            Write-Warn "image-gen: upgrade backup verification failed - aborting upgrade (prior install left intact)"
            if ($backupDir -and (Test-Path $backupDir)) { Remove-Item $backupDir -Recurse -Force -ErrorAction SilentlyContinue }
            $script:InstallWarnings++
            return
        }
    }

    # Restore helper: on verified success returns 0; on failure returns 1 and
    # the backup is RETAINED so manual recovery is possible. The caller emits
    # the retained path and increments warnings. Backup is deleted ONLY after a
    # fully verified restore or a completed successful upgrade.
    function Restore-ImageGenPrev {
        if (-not $backupDir) {
            # Fresh: remove what npx created so no unowned half-install lingers.
            try {
                if (Test-Path -LiteralPath $skillDir) { Remove-Item -LiteralPath $skillDir -Recurse -Force }
                if (Test-Path -LiteralPath $manifest) { Remove-Item -LiteralPath $manifest -Force -ErrorAction SilentlyContinue }
            } catch { return 1 }
            if (Test-Path -LiteralPath $skillDir) { return 1 }
            return 0
        }
        try {
            if (Test-Path -LiteralPath $skillDir) { Remove-Item -LiteralPath $skillDir -Recurse -Force }
            if (Test-Path -LiteralPath $skillDir) { return 1 }
            $rtmp = Join-Path (Split-Path -Parent $skillDir) (".image-gen-restore." + (Get-Random))
            New-Item -ItemType Directory -Path $rtmp -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $backupDir "image-gen") -Destination (Join-Path $rtmp "image-gen") -Recurse -Force
            Copy-Item -LiteralPath (Join-Path $backupDir "manifest") -Destination (Join-Path $rtmp "manifest") -Force
            if (-not (Test-Path (Join-Path $rtmp "image-gen")) `
                -or -not (Test-Path (Join-Path $rtmp "image-gen\image_gen.py")) `
                -or -not (Test-ImageGenMarkersStrict -SkillMd (Join-Path $rtmp "image-gen\SKILL.md")) `
                -or -not (Test-ImageGenManifestValid -Manifest (Join-Path $rtmp "manifest"))) {
                Remove-Item $rtmp -Recurse -Force -ErrorAction SilentlyContinue
                return 1
            }
            Move-Item -LiteralPath (Join-Path $rtmp "image-gen") -Destination $skillDir -Force
            Move-Item -LiteralPath (Join-Path $rtmp "manifest") -Destination $manifest -Force
            Remove-Item $rtmp -Recurse -Force -ErrorAction SilentlyContinue
            return 0
        } catch {
            return 1
        }
    }

    # Run npx with DO_NOT_TRACK=1 and restore it in finally (telemetry off).
    # Invoke-ImageGenNpx detaches stdin (EOF immediately), uses a constant
    # argument array, handles npx.cmd, and checks the exit code. 3 attempts,
    # 5s delay, bounded to image-gen.
    $prevDnt = $env:DO_NOT_TRACK
    $env:DO_NOT_TRACK = "1"
    $npxOk = $false
    try {
        $npxOk = Invoke-Retry -MaxAttempts 3 -DelaySeconds 5 -Description "image-gen Skill" -Action {
            $localArgs = $npxArgs
            if (-not (Invoke-ImageGenNpx -NpxArgs $localArgs)) { throw "npx skills exited non-zero (or failed to start)" }
        }
    } finally {
        $env:DO_NOT_TRACK = $prevDnt
    }

    if (-not $npxOk) {
        Write-Warn "Failed to install image-gen Skill via npx (always-installed - install skipped)."
        Write-Warn "  Retry manually: `$env:DO_NOT_TRACK='1'; $cmdPreview"
        $rc = Restore-ImageGenPrev
        if ($rc -ne 0 -and $backupDir) {
            Write-Warn "image-gen: npx failed - restore FAILED, prior-install backup RETAINED at: $backupDir (manual recovery needed)"
        }
        $script:InstallWarnings++
        return
    }
    Write-Ok "image-gen Skill installed (~/.claude/skills/image-gen/)"

    $wrapper = Join-Path $CLAUDE_DIR "scripts\image-gen-cliproxyapi.sh"
    if (-not (Test-Path -LiteralPath $wrapper)) {
        Write-Warn "image-gen wrapper not installed at $wrapper - augmentation/manifest skipped"
        $rc = Restore-ImageGenPrev
        if ($rc -ne 0 -and $backupDir) {
            Write-Warn "image-gen: wrapper missing - restore FAILED, prior-install backup RETAINED at: $backupDir (manual recovery needed)"
        }
        $script:InstallWarnings++
        return
    }

    if (-not (Update-ImageGenSkillInstructions -SkillsDir (Join-Path $CLAUDE_DIR "skills"))) {
        Write-Warn "image-gen: SKILL.md augmentation failed - ownership manifest NOT written"
        $rc = Restore-ImageGenPrev
        if ($rc -ne 0 -and $backupDir) {
            Write-Warn "image-gen: augment failed - restore FAILED, prior-install backup RETAINED at: $backupDir (manual recovery needed)"
        }
        $script:InstallWarnings++
        return
    }
    Write-Ok "image-gen: SKILL.md augmented with managed integration block"

    if (-not (Write-ImageGenManifest -Manifest $manifest)) {
        Write-Warn "image-gen: failed to write ownership manifest"
        $rc = Restore-ImageGenPrev
        if ($rc -ne 0 -and $backupDir) {
            Write-Warn "image-gen: manifest write failed - restore FAILED, prior-install backup RETAINED at: $backupDir (manual recovery needed)"
        }
        $script:InstallWarnings++
        return
    }
    # Successful upgrade: the backup is no longer needed.
    if ($backupDir -and (Test-Path $backupDir)) { Remove-Item $backupDir -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Ok "image-gen: ownership manifest written ($manifest)"
}

function Install-DeepXiv {
    param(
        [string[]]$SelectedDeepXivSkills = @()
    )
    $repoUrl = "https://github.com/DeepXiv/deepxiv_sdk"
    $knownSkills = @("deepxiv-cli", "deepxiv-trending-digest", "deepxiv-baseline-table")

    Write-Info "Installing DeepXiv skills from github.com/DeepXiv/deepxiv_sdk..."
    $skillsDir = Join-Path $CLAUDE_DIR "skills"
    if (-not $DryRun) { New-Item -ItemType Directory -Path $skillsDir -Force | Out-Null }

    # Pre-flight: git must be available
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Err "git is required to install DeepXiv skills but was not found. Please install git first."
        return
    }

    # When no specific skills selected (--All mode), use the known bounded list
    if ($SelectedDeepXivSkills.Count -eq 0) {
        $SelectedDeepXivSkills = $knownSkills
    }

    $deepxivTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("deepxiv_sdk_" + [System.IO.Path]::GetRandomFileName())

    $cloneOk = $false
    if ($DryRun) {
        Write-Info "Would clone $repoUrl (shallow) to temporary directory"
        $cloneOk = $true
    } else {
        $cloneOk = Invoke-Retry -MaxAttempts 3 -DelaySeconds 3 -Description "Clone deepxiv_sdk" -Action {
            git clone --depth 1 $repoUrl $deepxivTmp
            if ($LASTEXITCODE -ne 0) { throw "git clone failed" }
        }
        if ($cloneOk) {
            Write-Ok "DeepXiv SDK repo cloned (latest)"
        } else {
            Write-Err "Failed to clone deepxiv_sdk repo. Check network/proxy and try again."
            $script:InstallWarnings++
            if (Test-Path $deepxivTmp) { Remove-Item $deepxivTmp -Recurse -Force }
            return
        }
    }

    if ($cloneOk -and -not $DryRun) {
        $srcSkills = Join-Path $deepxivTmp "skills"
        if (-not (Test-Path $srcSkills)) {
            Write-Err "deepxiv_sdk/skills directory not found in cloned repo"
            $script:InstallWarnings++
            Remove-Item $deepxivTmp -Recurse -Force
            return
        }

        foreach ($skill in $SelectedDeepXivSkills) {
            $src = Join-Path $srcSkills $skill
            $dst = Join-Path $skillsDir $skill
            if (Test-Path $src) {
                if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
                Copy-Item $src $dst -Recurse -Force
                Write-Ok "DeepXiv skill installed: $skill"
            } else {
                Write-Warn "DeepXiv skill not found in repo: $skill"
                $script:InstallWarnings++
            }
        }
    } elseif ($DryRun) {
        foreach ($skill in $SelectedDeepXivSkills) {
            Write-Info "Would install DeepXiv skill: $skill -> $skillsDir\$skill"
        }
    }

    # Clean up
    if (Test-Path $deepxivTmp) { Remove-Item $deepxivTmp -Recurse -Force }
}

function Install-Lessons {
    Write-Info "Installing lessons.md template..."
    $target = Join-Path $CLAUDE_DIR "lessons.md"
    if (Test-Path $target) {
        Write-Warn "lessons.md already exists -- skipping"
    } else {
        if ($DryRun) {
            Write-Info "Would copy: lessons.md -> $target"
        } else {
            Copy-Item (Join-Path $SCRIPT_DIR "lessons.md") $target -Force
            Write-Ok "lessons.md template installed to $target"
        }
    }
}

function Install-Hooks {
    Write-Info "Installing hooks..."
    $hooksDir = Join-Path $CLAUDE_DIR "hooks"
    if (-not $DryRun) { New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null }

    Get-ChildItem (Join-Path $SCRIPT_DIR "hooks") -File | ForEach-Object {
        $fname = $_.Name
        $dst = Join-Path $hooksDir $fname
        if ($DryRun) {
            Write-Info "Would copy: hooks\$fname -> $dst"
        } else {
            Copy-Item $_.FullName $dst -Force
            Write-Ok "Hook installed: $fname"
        }
    }

    # Ensure jq is available (required by statusline.sh)
    Install-Jq

    # Install Nerd Font for statusline icons
    Install-NerdFont

    # Check bash availability (required by statusline and SessionStart hooks)
    if (-not (Get-Command bash -ErrorAction SilentlyContinue)) {
        Write-Warn "bash not found in PATH. Statusline and SessionStart hooks require bash."
        Write-Warn "  Install Git for Windows (includes Git Bash): https://git-scm.com/download/win"
        Write-Warn "  Or install WSL: wsl --install"
        $script:InstallWarnings++
    }
}

function Install-Jq {
    if (Get-Command jq -ErrorAction SilentlyContinue) {
        Write-Ok "jq already available in PATH"
        return
    }

    $binDir = Join-Path $CLAUDE_DIR "bin"
    $jqPath = Join-Path $binDir "jq.exe"
    if (Test-Path $jqPath) {
        Write-Ok "jq already installed at $jqPath"
        return
    }

    if ($DryRun) {
        Write-Info "Would download jq.exe -> $jqPath"
        return
    }

    Write-Info "Downloading jq (required by statusline)..."
    New-Item -ItemType Directory -Path $binDir -Force | Out-Null

    $arch = if ([Environment]::Is64BitOperatingSystem) { "amd64" } else { "i386" }
    $jqUrl = "https://github.com/jqlang/jq/releases/latest/download/jq-windows-$arch.exe"

    $ok = Invoke-Retry -MaxAttempts 3 -DelaySeconds 2 -Description "Download jq" -Action {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $jqUrl -OutFile $jqPath -UseBasicParsing
    }
    if ($ok) {
        Write-Ok "jq installed to $jqPath"
    } else {
        Write-Warn "Could not download jq. Install it manually: https://jqlang.github.io/jq/download/"
        Write-Warn "Or run: winget install jqlang.jq"
    }
}

function Install-NerdFont {
    # Check if already installed
    $fontDir = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Fonts"
    if ((Test-Path $fontDir) -and (Get-ChildItem $fontDir -Filter "*MesloLGS NF*" -ErrorAction SilentlyContinue)) {
        return
    }

    if ($DryRun) {
        Write-Info "Would install MesloLGS NF font"
        return
    }

    Write-Info "Installing MesloLGS NF font for statusline icons..."

    # Copy bundled fonts from repository
    $srcDir = Join-Path $SCRIPT_DIR "fonts"
    $ttfFiles = Get-ChildItem $srcDir -Filter "*.ttf" -ErrorAction SilentlyContinue
    if (-not $ttfFiles) {
        Write-Warn "Bundled fonts not found in $srcDir - statusline will use text fallback"
        return
    }

    try {
        # Install to user fonts directory
        if (-not (Test-Path $fontDir)) {
            New-Item -ItemType Directory -Path $fontDir -Force | Out-Null
        }

        $regPath = "HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"
        $ttfFiles | ForEach-Object {
            $dst = Join-Path $fontDir $_.Name
            Copy-Item $_.FullName $dst -Force
            # Register font in user registry
            $fontName = [System.IO.Path]::GetFileNameWithoutExtension($_.Name) + " (TrueType)"
            New-ItemProperty -Path $regPath -Name $fontName -Value $dst -PropertyType String -Force | Out-Null
        }

        Write-Ok "MesloLGS NF font installed"
        Write-Warn "Set your terminal font to 'MesloLGS NF' for best icon display"
    } catch {
        Write-Warn "Could not install Nerd Font: $_"
    }
}

function Install-Mcp {
    param(
        [bool]$InstallPlaywright = $true,
        [bool]$InstallLark = $false
    )
    Write-Info "Installing MCP servers..."
    $claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
    if (-not $claudeCmd) {
        Write-Err "Claude Code CLI not found. Install it first: https://claude.com/claude-code"
        return
    }

    # Helper: check if an MCP server already exists
    function Test-McpExists($name) {
        $list = & claude mcp list 2>$null
        if ($list -match "^${name}:") { return $true }
        return $false
    }

    # Lark MCP -- opt-in only (default off). Prompt for credentials in
    # interactive mode, skip in non-interactive. Not installed unless the user
    # explicitly selected "Lark/Feishu MCP" (or passed -All).
    if (-not $InstallLark) {
        # Lark not selected -- skip entirely
    } elseif ($DryRun) {
        Write-Info "Would add MCP server: lark-mcp (stdio)"
    } else {
        if (Test-McpExists "lark-mcp") {
            Write-Ok "MCP server lark-mcp already exists, skipping"
        } elseif (-not $Force -or -not ([Environment]::UserInteractive -and $Host.Name -eq "ConsoleHost")) {
            # Non-interactive or piped mode: skip with warning
            Write-Warn "Skipping lark-mcp (requires interactive credential input)"
            Write-Warn "  Run interactively to set up, or add manually:"
            Write-Warn "  claude mcp add --scope user --transport stdio lark-mcp -- npx -y `"@larksuiteoapi/lark-mcp`" mcp -a <APP_ID> -s <APP_SECRET>"
        } else {
            # Interactive mode: prompt for credentials
            Write-Host ""
            Write-Info "Lark MCP requires Feishu App credentials:"
            Write-Info "  Get them from: https://open.feishu.cn/app"
            $larkAppId = Read-Host "  App ID"
            $larkAppSecret = Read-Host "  App Secret"
            if ([string]::IsNullOrWhiteSpace($larkAppId) -or [string]::IsNullOrWhiteSpace($larkAppSecret)) {
                Write-Warn "Empty credentials -- skipping lark-mcp (add manually later)"
            } else {
                $ok = Invoke-Retry -MaxAttempts 3 -DelaySeconds 3 -Description "Add MCP server lark-mcp" -Action {
                    & claude mcp add --scope user --transport stdio lark-mcp -- npx -y "@larksuiteoapi/lark-mcp" mcp -a $larkAppId -s $larkAppSecret 2>$null
                }
                if ($ok) { Write-Ok "MCP server added: lark-mcp" }
                else { Write-Warn "MCP server lark-mcp could not be added, skipping" }
            }
        }
    }

    # Playwright MCP
    if (-not $InstallPlaywright) {
        # Playwright not selected -- skip entirely
    } elseif ($DryRun) {
        Write-Info "Would add MCP server: playwright (stdio)"
    } else {
        if (Test-McpExists "playwright") {
            Write-Ok "MCP server playwright already exists, skipping"
        } else {
            $ok = Invoke-Retry -MaxAttempts 5 -DelaySeconds 3 -Description "Add MCP server playwright" -Action {
                & claude mcp add --scope user --transport stdio playwright -- npx @playwright/mcp@latest 2>$null
            }
            if ($ok) { Write-Ok "MCP server added: playwright" }
            else { Write-Warn "MCP server playwright could not be added, skipping" }
        }
    }
}

function Install-Plugins {
    param(
        [string[]]$Groups = @("essential"),
        [string[]]$SelectedPluginsList = @()
    )

    $claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
    if (-not $claudeCmd) {
        Write-Err "Claude Code CLI not found. Install it first: https://claude.com/claude-code"
        return
    }

    # Collect plugins from individually selected + group-based
    $plugins = @()
    if ($SelectedPluginsList.Count -gt 0) { $plugins += $SelectedPluginsList }
    foreach ($group in $Groups) {
        switch ($group) {
            "essential" { $plugins += $PLUGINS_ESSENTIAL }
            "claude-mem" { $plugins += $PLUGINS_CLAUDE_MEM }
            "ai-research" { $plugins += $PLUGINS_AI_RESEARCH }
            "pua" { $plugins += $PLUGINS_PUA }
            "all" { $plugins += $PLUGINS_ESSENTIAL + $PLUGINS_OPTIONAL + $PLUGINS_CLAUDE_MEM + $PLUGINS_AI_RESEARCH + $PLUGINS_PUA }
        }
    }

    # Deduplicate
    $plugins = @($plugins | Select-Object -Unique)

    # Expose this run's selection so Remove-UnlistedPlugins can reconcile.
    $script:ResolvedPlugins = $plugins

    $groupNames = $Groups -join ","
    Write-Info "Installing plugins (groups: $groupNames)..."

    # Snapshot what's already installed so we can reinstall (= update) selected
    # plugins that are already present instead of a plain install.
    $installedKeys = Get-InstalledPluginKeys

    # Collect needed marketplaces
    $neededMarketplaces = @{}
    foreach ($entry in $plugins) {
        $marketplace = ($entry -split '@')[-1]
        $neededMarketplaces[$marketplace] = $true
    }

    # Step 1: Add required marketplaces
    Write-Info "Adding marketplaces..."
    foreach ($mp in $MARKETPLACE_LIST) {
        if (-not $neededMarketplaces.ContainsKey($mp.Name)) { continue }

        # Skip if already installed
        $mpDir = Join-Path $env:USERPROFILE ".claude\plugins\marketplaces\$($mp.Name)"
        if (Test-Path $mpDir) {
            Write-Ok "Marketplace already exists: $($mp.Name)"
            continue
        }

        if ($DryRun) {
            Write-Info "Would add marketplace: $($mp.Name) (github.com/$($mp.Repo))"
        } else {
            $ok = Invoke-Retry -MaxAttempts 5 -DelaySeconds 3 -Description "Add marketplace $($mp.Name)" -Action {
                & claude plugin marketplace add "https://github.com/$($mp.Repo)" 2>$null
            }
            if ($ok) { Write-Ok "Marketplace added: $($mp.Name)" }
            else { Write-Warn "Marketplace $($mp.Name) may already exist or could not be added" }
        }
    }

    # Step 2: Install (or reinstall) plugins.
    # Update mechanism is uninstall-then-reinstall: if a selected plugin is
    # already installed (rule 2), uninstall it first so it is reinstalled fresh.
    Write-Info "Installing $($plugins.Count) plugins..."
    foreach ($entry in $plugins) {
        $parts = $entry -split '@'
        $pluginName = $parts[0]
        $alreadyInstalled = ($installedKeys -contains $entry)
        if ($DryRun) {
            if ($alreadyInstalled) {
                Write-Info "Would reinstall plugin (update): $pluginName from $($parts[1])"
            } else {
                Write-Info "Would install plugin: $pluginName from $($parts[1])"
            }
        } else {
            # Reinstall = update: remove the existing copy before installing.
            if ($alreadyInstalled) {
                & claude plugin uninstall "$entry" 2>$null
            }
            $ok = Invoke-Retry -MaxAttempts 5 -DelaySeconds 3 -Description "Install plugin $pluginName" -Action {
                & claude plugin install "$entry" 2>$null
            }
            if ($ok) { Write-Ok "Plugin installed: $pluginName" }
            else { Write-Warn "Plugin $pluginName could not be installed, skipping"; $script:InstallWarnings++ }
        }
    }
}

# Refresh ALL marketplace catalogs and update every installed plugin to its
# latest version. Mirrors update_installed_plugins() in install.sh. Runs on
# every invocation, independent of which components were selected, so a plain
# re-run of install.ps1 keeps third-party plugins current — the built-in
# session auto-update skips community marketplaces. Uses native JSON parsing
# (no jq). A Claude Code restart is required for updates to take effect.
# Uninstall plugins and remove marketplaces that were renamed/removed upstream.
function Remove-RetiredPlugins {
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { return }
    $listJson = Join-Path $env:USERPROFILE ".claude\plugins\installed_plugins.json"
    $installedKeys = @()
    if (Test-Path $listJson) {
        try {
            $parsed = Get-Content $listJson -Raw | ConvertFrom-Json
            if ($parsed.PSObject.Properties['plugins']) {
                $installedKeys = $parsed.plugins.PSObject.Properties.Name
            }
        } catch { }
    }
    foreach ($pkg in $RETIRED_PLUGINS) {
        if ($installedKeys -notcontains $pkg) { continue }
        if ($DryRun) {
            Write-Info "Would uninstall retired plugin: $pkg"
        } else {
            & claude plugin uninstall "$pkg" 2>$null
            if ($LASTEXITCODE -eq 0) { Write-Ok "Removed retired plugin: $pkg" }
            else { Write-Warn "Could not uninstall retired plugin: $pkg (may already be gone)" }
        }
    }
    foreach ($mkt in $RETIRED_MARKETPLACES) {
        $mktDir = Join-Path $env:USERPROFILE ".claude\plugins\marketplaces\$mkt"
        if (-not (Test-Path $mktDir)) { continue }
        if ($DryRun) {
            Write-Info "Would remove retired marketplace: $mkt"
        } else {
            & claude plugin marketplace remove "$mkt" 2>$null
            if ($LASTEXITCODE -eq 0) { Write-Ok "Removed retired marketplace: $mkt" }
            else { Write-Warn "Could not remove retired marketplace: $mkt" }
        }
    }
}

# Prune installer-managed plugins that are installed but were NOT selected this
# run (rule 1). Preserves user-owned third-party plugins (rule 4). Must run
# AFTER Install-Plugins so $script:ResolvedPlugins reflects the selection.
# Mirrors prune_unlisted_plugins() in install.sh.
function Remove-UnlistedPlugins {
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { return }
    # An empty resolved set must NEVER imply "prune everything" (e.g. the plugin
    # step ran but the user deselected all plugins). Guard before computing.
    if ($script:ResolvedPlugins.Count -eq 0) { return }

    $installed = Get-InstalledPluginKeys
    if ($installed.Count -eq 0) { return }
    $catalogue = Get-PluginCatalogue
    $toPrune = Get-PluginsToPrune -Catalogue $catalogue -Selected $script:ResolvedPlugins -Installed $installed

    foreach ($pkg in $toPrune) {
        if ($DryRun) {
            Write-Info "Would uninstall unlisted plugin: $pkg"
        } else {
            & claude plugin uninstall "$pkg" 2>$null
            if ($LASTEXITCODE -eq 0) { Write-Ok "Pruned plugin (no longer selected): $pkg" }
            else { Write-Warn "Could not uninstall plugin: $pkg (may already be gone)" }
        }
    }
}

function Update-InstalledPlugins {
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        Write-Info "claude CLI not found - skipping plugin updates"
        return
    }

    $listJson = Join-Path $env:USERPROFILE ".claude\plugins\installed_plugins.json"

    # Skip installer-managed catalogue plugins here: selected ones were just
    # reinstalled fresh, unselected ones were already pruned. Only update the
    # PRESERVED user-owned third-party plugins; never resurrect a pruned plugin.
    $catalogue = Get-PluginCatalogue

    if ($DryRun) {
        Write-Info "Would run: claude plugin marketplace update (all catalogs)"
        if (Test-Path $listJson) {
            try {
                $data = Get-Content $listJson -Raw | ConvertFrom-Json
                if ($data.PSObject.Properties['plugins']) {
                    foreach ($name in $data.plugins.PSObject.Properties.Name) {
                        if ($catalogue -contains $name) { continue }
                        Write-Info "Would update plugin: $name"
                    }
                }
            } catch { }
        }
        return
    }

    Write-Info "Refreshing marketplace catalogs (official + third-party)..."
    $ok = Invoke-Retry -MaxAttempts 3 -DelaySeconds 3 -Description "Refresh marketplaces" -Action {
        & claude plugin marketplace update 2>$null
        if ($LASTEXITCODE -ne 0) { throw "marketplace update failed" }
    }
    if ($ok) { Write-Ok "Marketplace catalogs refreshed" }
    else { Write-Warn "Could not refresh some marketplace catalogs" }

    if (-not (Test-Path $listJson)) {
        Write-Warn "installed_plugins.json not found - cannot enumerate installed plugins to update"
        return
    }

    $plugins = $null
    try {
        $parsed = Get-Content $listJson -Raw | ConvertFrom-Json
        if ($parsed.PSObject.Properties['plugins']) { $plugins = $parsed.plugins }
    } catch {
        Write-Warn "installed_plugins.json is not valid JSON - skipping plugin updates"
        return
    }
    if (-not $plugins) {
        Write-Warn "No installed plugins found in installed_plugins.json"
        return
    }

    Write-Info "Updating preserved third-party plugins to latest (restart required to apply)..."
    foreach ($name in $plugins.PSObject.Properties.Name) {
        # Skip installer-managed plugins (already reinstalled or pruned above).
        if ($catalogue -contains $name) { continue }
        $shortName = ($name -split '@')[0]
        $ok = Invoke-Retry -MaxAttempts 3 -DelaySeconds 3 -Description "Update plugin $name" -Action {
            & claude plugin update "$name"
            if ($LASTEXITCODE -ne 0) { throw "plugin update failed" }
        }
        if ($ok) { Write-Ok "Plugin updated: $shortName" }
        else { Write-Warn "Could not update plugin: $name" }
    }
}

# --- Uninstall -------------------------------------------------------------

function Invoke-Uninstall {
    Write-Host ""
    Write-Warn "The following will be removed:"
    Write-Host "  - $CLAUDE_DIR\CLAUDE.md"
    Write-Host "  - $CLAUDE_DIR\settings.json (backed up first)"
    Write-Host "  - $CLAUDE_DIR\rules\"
    Write-Host "  - $CLAUDE_DIR\skills\ (installer-managed only)"
    Write-Host "  - $CLAUDE_DIR\agents\ (installer-managed only)"
    Write-Host "  - $CLAUDE_DIR\skills\deepxiv-* (DeepXiv skills)"
    Write-Host "  - $CLAUDE_DIR\skills\image-gen\ (when installer-owned, via .image-gen-sinedied)"
    Write-Host "  - $CLAUDE_DIR\scripts\image-gen-cliproxyapi.sh (image-gen wrapper)"
    Write-Host "  - $CLAUDE_DIR\.image-gen-sinedied (image-gen ownership manifest)"
    Write-Host "  - $CLAUDE_DIR\lessons.md"
    Write-Host "  - $CLAUDE_DIR\hooks\ (installer-managed only)"
    Write-Host "  - Installed plugins (requires claude CLI)"
    Write-Host "  - MCP servers: playwright, lark-mcp (if present; requires claude CLI)"
    if (Test-Path $VERSION_STAMP_FILE) {
        Write-Host "  - $VERSION_STAMP_FILE"
    }
    Write-Host ""

    if ($DryRun) {
        Write-Warn "DRY RUN -- nothing will be removed"
        return
    }

    if (-not (Confirm-Action "Proceed with uninstall?")) {
        Write-Info "Cancelled."
        exit 0
    }

    $p = Join-Path $CLAUDE_DIR "CLAUDE.md"
    if (Test-Path $p) { Remove-Item $p -Force; Write-Ok "Removed CLAUDE.md" }

    $p = Join-Path $CLAUDE_DIR "settings.json"
    if (Test-Path $p) {
        Copy-Item $p (Join-Path $CLAUDE_DIR "settings.json.bak") -Force
        Write-Ok "Backed up settings.json -> settings.json.bak"
        Remove-Item $p -Force; Write-Ok "Removed settings.json"
    }

    $p = Join-Path $CLAUDE_DIR "rules"
    if (Test-Path $p) { Remove-Item $p -Recurse -Force; Write-Ok "Removed rules/" }

    # Only remove skills that ship with this repo. When the source inventory is
    # absent we NEVER blanket-delete $CLAUDE_DIR\skills — that would remove
    # user-authored and installer-managed skills we cannot enumerate. The
    # image-gen ownership manifest is the sole authority for image-gen (handled
    # below); everything else is preserved when no inventory exists.
    $skillsSrc = Join-Path $SCRIPT_DIR "skills"
    if (Test-Path $skillsSrc) {
        Get-ChildItem $skillsSrc -Directory | ForEach-Object {
            $sp = Join-Path $CLAUDE_DIR "skills\$($_.Name)"
            if (Test-Path $sp) { Remove-Item $sp -Recurse -Force; Write-Ok "Removed skill: $($_.Name)" }
        }
    } else {
        Write-Warn "No source skills inventory ($skillsSrc missing) - leaving $CLAUDE_DIR\skills untouched (installer-managed + user skills preserved; the image-gen manifest governs image-gen only)"
    }

    # Only remove agents that ship with this repo
    $agentsSrc = Join-Path $SCRIPT_DIR "agents"
    if (Test-Path $agentsSrc) {
        Get-ChildItem $agentsSrc -Filter "*.md" | ForEach-Object {
            $ap = Join-Path $CLAUDE_DIR "agents\$($_.Name)"
            if (Test-Path $ap) { Remove-Item $ap -Force; Write-Ok "Removed agent: $($_.Name)" }
        }
    } else {
        $p = Join-Path $CLAUDE_DIR "agents"
        if (Test-Path $p) { Remove-Item $p -Recurse -Force; Write-Ok "Removed agents/" }
    }

    # Only remove maintenance scripts that this installer manages
    foreach ($script in $USER_SCRIPTS) {
        $sp = Join-Path $CLAUDE_DIR "scripts\$script"
        if (Test-Path $sp) { Remove-Item $sp -Force; Write-Ok "Removed script: $script" }
    }
    $scriptsDir = Join-Path $CLAUDE_DIR "scripts"
    if ((Test-Path $scriptsDir) -and -not (Get-ChildItem $scriptsDir -ErrorAction SilentlyContinue)) {
        Remove-Item $scriptsDir -Force
    }

    # Remove DeepXiv skills (glob to catch any installed by --All)
    $deepxivPattern = Join-Path $CLAUDE_DIR "skills\deepxiv-*"
    Get-ChildItem $deepxivPattern -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item $_.FullName -Recurse -Force; Write-Ok "Removed DeepXiv skill: $($_.Name)"
    }

    # Remove the image-gen Skill ONLY when the ownership manifest proves this
    # installer installed it. Validates EVERY fixed field via the byte-exact
    # manifest validator AND the strict augmentation-marker check before any
    # delete, so a user-authored directory whose name collides with image-gen
    # is never recursively deleted. The wrapper is removed by the USER_SCRIPTS
    # loop above; here we only handle the Skill directory and the manifest.
    $igManifest = Join-Path $CLAUDE_DIR ".image-gen-sinedied"
    if (Test-Path -LiteralPath $igManifest) {
        if (Test-ImageGenDirOwned -SkillDir (Join-Path $CLAUDE_DIR "skills\image-gen") -Manifest $igManifest) {
            $igDir = Join-Path $CLAUDE_DIR "skills\image-gen"
            if (Test-Path -LiteralPath $igDir) {
                Remove-Item -LiteralPath $igDir -Recurse -Force; Write-Ok "Removed image-gen Skill (installer-owned)"
            }
            Remove-Item -LiteralPath $igManifest -Force; Write-Ok "Removed image-gen ownership manifest"
        } else {
            Write-Warn "image-gen: ownership proof incomplete (valid manifest + augmentation markers both required) - leaving ~/.claude/skills/image-gen untouched and removing only the stale manifest"
            Remove-Item -LiteralPath $igManifest -Force -ErrorAction SilentlyContinue
        }
    }

    Remove-RetiredSkills

    $p = Join-Path $CLAUDE_DIR "lessons.md"
    if (Test-Path $p) { Remove-Item $p -Force; Write-Ok "Removed lessons.md" }

    # Only remove hooks that ship with this repo
    $hooksSrc = Join-Path $SCRIPT_DIR "hooks"
    if (Test-Path $hooksSrc) {
        Get-ChildItem $hooksSrc -File | ForEach-Object {
            $hp = Join-Path $CLAUDE_DIR "hooks\$($_.Name)"
            if (Test-Path $hp) { Remove-Item $hp -Force; Write-Ok "Removed hook: $($_.Name)" }
        }
    } else {
        $p = Join-Path $CLAUDE_DIR "hooks"
        if (Test-Path $p) { Remove-Item $p -Recurse -Force; Write-Ok "Removed hooks/" }
    }

    $claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
    if ($claudeCmd) {
        $allPlugins = $PLUGINS_ESSENTIAL + $PLUGINS_OPTIONAL + $PLUGINS_CLAUDE_MEM + $PLUGINS_AI_RESEARCH + $PLUGINS_PUA + $PLUGINS_REMOVED
        foreach ($entry in $allPlugins) {
            $pluginName = ($entry -split '@')[0]
            & claude plugin uninstall $entry 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Ok "Uninstalled plugin: $pluginName"
            } else {
                Write-Warn "Could not uninstall: $pluginName"
            }
        }
        & claude mcp remove lark-mcp 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "Removed MCP server: lark-mcp"
        } else {
            Write-Warn "Could not remove lark-mcp"
        }
        & claude mcp remove playwright 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "Removed MCP server: playwright"
        } else {
            Write-Warn "Could not remove playwright"
        }
    } else {
        Write-Warn "Claude CLI not found - cannot uninstall plugins or MCP servers"
    }

    if (Test-Path $VERSION_STAMP_FILE) { Remove-Item $VERSION_STAMP_FILE -Force }
    Write-Host ""
    Write-Ok "Uninstall complete."
}

# --- Help ------------------------------------------------------------------

function Show-Help {
    Write-Host @"

Usage: .\install.ps1 [OPTIONS]

Install Claude Code configuration files.

Running without options launches an interactive component selector.
Works with both local and remote installs (irm | iex).

Options:
    -All                Install everything (non-interactive)
    -Uninstall          Remove all installed files
    -Version            Show version info
    -DryRun             Show what would be installed without doing it
    -Force              Skip confirmation prompts
    -Help               Show this help

Examples:
    .\install.ps1                  # Interactive selector
    .\install.ps1 -All             # Install everything
    .\install.ps1 -Uninstall       # Uninstall everything
    .\install.ps1 -DryRun -All     # Preview full install
    & ([scriptblock]::Create((irm $($script:REPO_URL)/raw/$($script:REPO_BRANCH)/install.ps1)))  # Remote install

"@
}

# --- Main ------------------------------------------------------------------

function Main {
    Initialize-ScriptDir

    # Remote DryRun short-circuit: source was NOT downloaded (no network/temp
    # write), so we cannot enumerate components. Print a sanitized plan and
    # exit without touching USERPROFILE or temp.
    if ($script:REMOTE_DRY_RUN) {
        # Source was NOT downloaded (SCRIPT_DIR is empty), so Get-SourceVersion
        # must NOT be called (it would read a relative "VERSION" from CWD). Print
        # a safe planned-source label derived from the known branch/env only.
        $plannedVer = if ($env:VERSION) { $env:VERSION } else { $script:REPO_BRANCH }
        Write-Host ""
        Write-Host "========================================="
        Write-Host "  Awesome Claude Code Config Installer"
        Write-Host "  remote DryRun (would fetch: $plannedVer)"
        Write-Host "========================================="
        Write-Host ""
        Write-Warn "DRY RUN (remote) -- source not downloaded; no network, USERPROFILE, or temp writes"
        Write-Info "Would download $plannedVer from $($script:REPO_URL), then install selected components into $CLAUDE_DIR"
        if ($All) { Write-Info "Mode: -All (everything)" } else { Write-Info "Mode: interactive selector" }
        return
    }

    if ($Help) { Show-Help; return }
    if ($Version) { Show-Version; return }
    if ($Uninstall) {
        Write-Host ""
        Write-Host "========================================="
        Write-Host "  Claude Code Config - Uninstaller"
        Write-Host "========================================="
        Invoke-Uninstall
        return
    }

    # Determine mode
    $doClaudeMd = $false
    $doSettings = $false
    $doRules = $false
    $doSkills = $false
    $doAgents = $false
    $doLessons = $false
    $doHooks = $false
    $doPlugins = $false
    $doMcp = $false
    $doLark = $false
    $doDeepXiv = $false
    $deepXivSkills = @()
    $ruleLangs = @()
    $ruleLangsExplicit = $false
    $pluginGroups = @()
    $selectedSkills = @()
    $selectedPlugins = @()
    $reviewAdversarial = $false
    $reviewCodex = $false

    if ($All) {
        # Explicit -All: install everything including MCP
        # mattpocock/skills is installed by default (replaces the former handoff/teach skills)
        $doClaudeMd = $true
        $doSettings = $true
        $doRules = $true
        $doSkills = $true
        $doAgents = $true
        $doLessons = $true
        $doHooks = $true
        $doPlugins = $true
        $doMcp = $true
        $doLark = $true   # -All means everything; lark still self-skips without credentials
        $doDeepXiv = $true
        $deepXivSkills = @("deepxiv-cli", "deepxiv-trending-digest", "deepxiv-baseline-table")
        $pluginGroups = @("all")
        # Both OFF so CLAUDE.md points at the code-reviewer agent: -All does not
        # install the codex CLI, and adversarial-review hard-requires `codex exec`.
        # The skill files themselves are still installed by -All.
        $reviewAdversarial = $false
        $reviewCodex = $false
        $selectedPlugins = @("code-review@claude-plugins-official")
        $selectedSkills = @()
    } elseif ([Environment]::UserInteractive -and $Host.Name -eq "ConsoleHost") {
        # Interactive mode: show menu (with fallback if console APIs fail)
        $menuResult = $null
        try {
            $menuResult = Show-InteractiveMenu
        } catch {
            Write-Warn "Interactive menu unavailable: $_"
            Write-Info "Falling back to default install (essential plugins, no MCP)"
        }
        if ($null -ne $menuResult) {
            $doClaudeMd = $menuResult.ClaudeMd
            $doSettings = $menuResult.Settings
            $doRules = $menuResult.Rules
            $doSkills = $menuResult.Skills
            $doAgents = $menuResult.Agents
            $doLessons = $menuResult.Lessons
            $doHooks = $menuResult.Hooks
            $doPlugins = $menuResult.Plugins
            $doMcp = $menuResult.Mcp
            $doLark = $menuResult.Lark
            $doDeepXiv = $menuResult.DeepXiv
            $deepXivSkills = $menuResult.DeepXivSkills
            $ruleLangs = $menuResult.RuleLangs
            $ruleLangsExplicit = $menuResult.RuleLangsExplicit
            $pluginGroups = $menuResult.PluginGroups
            $selectedSkills = $menuResult.SelectedSkills
            $selectedPlugins = $menuResult.SelectedPlugins
            $reviewAdversarial = $menuResult.ReviewAdversarial
            $reviewCodex = $menuResult.ReviewCodex
        } else {
            # Fallback when interactive menu failed
            # claude-mem is default OFF and only ships with explicit -All.
            $doClaudeMd = $true
            $doSettings = $true
            $doRules = $true
            $doSkills = $true
            $doLessons = $true
            $doHooks = $true
            $doPlugins = $true
            $pluginGroups = @("essential")
            $selectedPlugins = $PLUGINS_OPTIONAL
            $doMcp = $true
        }
    } else {
        # Non-interactive fallback: essential plugins plus the default-selected
        # third-party plugins and MCP servers, so a `irm | iex` install without
        # -All still brings them along. claude-mem is default OFF and only ships
        # with explicit -All. (lark-mcp is skipped non-interactively
        # as it needs credentials; playwright MCP installs fine.)
        $doClaudeMd = $true
        $doSettings = $true
        $doRules = $true
        $doSkills = $true
        $doLessons = $true
        $doHooks = $true
        $doPlugins = $true
        $pluginGroups = @("essential")
        $selectedPlugins = $PLUGINS_OPTIONAL
        $doMcp = $true
    }

    # Auto-enable settings.json when StatusLine, Lessons, or Plugins need it for config
    if (($doHooks -or $doLessons -or $doPlugins) -and -not $doSettings) {
        $doSettings = $true
        Write-Info "settings.json auto-enabled (required by StatusLine/Lessons/Plugins)"
    }

    # image-gen (sinedied/agent-skills) is an always-installed component with no
    # selectable flag and no menu item, so the former deselected-everything early
    # exit is removed: even when every selectable item is off, the installer still
    # proceeds to install maintenance scripts and the image-gen Skill. A user who
    # interactively deselects everything still gets the always-on floor.

    $sourceVer = Get-SourceVersion
    Write-Host ""
    Write-Host "========================================="
    Write-Host "  Awesome Claude Code Config Installer"
    Write-Host "  $sourceVer"
    Write-Host "========================================="
    Write-Host ""

    if ($DryRun) {
        Write-Warn "DRY RUN MODE -- no changes will be made"
        Write-Host ""
    }

    $installedVer = Get-InstalledVersion
    if ($installedVer -ne "not installed") {
        Write-Info "Upgrading from $installedVer -> $sourceVer"
    }

    # In DryRun perform NO filesystem writes at all (no mkdir) so the run is
    # fully side-effect-free and previewable from an empty USERPROFILE.
    if (-not $DryRun -and -not (Test-Path $CLAUDE_DIR)) {
        New-Item -ItemType Directory -Path $CLAUDE_DIR -Force | Out-Null
    }

    if ($doClaudeMd) { Install-ClaudeMd -ReviewAdversarial $reviewAdversarial -ReviewCodex $reviewCodex }
    if ($doSettings) { Install-Settings -InstallPlugins $doPlugins -SelectedPluginsList $selectedPlugins -PluginGroups $pluginGroups }
    if ($doRules) { Install-Rules -Langs $ruleLangs -LangsExplicit $ruleLangsExplicit }
    Remove-RetiredSkills
    Remove-RetiredEnabledPlugins
    if ($doSkills) { Install-Skills -SelectedSkills $selectedSkills }
    if ($doAgents) { Install-Agents }
    Install-Scripts
    # image-gen is always-installed (no flag gate). Runs after Install-Scripts
    # so the wrapper (a USER_SCRIPT) is already in place when augmentation and
    # the ownership-manifest write check for it.
    Install-ImageGen
    if ($doLessons) { Install-Lessons }
    if ($doHooks) { Install-Hooks }
    if ($doMcp -or $doLark) { Install-Mcp -InstallPlaywright $doMcp -InstallLark $doLark }
    Remove-RetiredPlugins
    if ($doPlugins) { Install-Plugins -Groups $pluginGroups -SelectedPluginsList $selectedPlugins }
    # Reconcile installed catalogue plugins against this run's selection: prune
    # installer-managed plugins that were NOT selected. Gated on $doPlugins so a
    # run that skips the plugin step never prunes (ResolvedPlugins would be empty
    # and wrongly mark every installed catalogue plugin for removal).
    if ($doPlugins) { Remove-UnlistedPlugins }
    # Always refresh marketplaces and update installed plugins, even when no
    # plugins were selected this run — keeps third-party plugins current.
    Update-InstalledPlugins
    if ($doDeepXiv) { Install-DeepXiv -SelectedDeepXivSkills $deepXivSkills }

    if (-not $DryRun) {
        if ($InstallCritical -eq 0) {
            Save-VersionStamp
        } else {
            Write-Warn "Skipping version stamp due to $InstallCritical critical warning(s)"
        }
    }

    # Data cleanup runs last so it also sweeps temp dirs created during this run
    # (e.g. plugin marketplace temp dirs from the updates above).
    Invoke-Cleanup

    Write-Host ""
    if ($InstallWarnings -gt 0 -or $InstallCritical -gt 0) {
        $total = $InstallWarnings + $InstallCritical
        Write-Warn "Installation completed with $total issue(s) ($InstallCritical critical, $InstallWarnings non-critical) - review messages above"
    } else {
        Write-Ok "Installation complete! ($sourceVer)"
    }
    Write-Host ""
    Write-Info "Next steps:"
    Write-Host "  1. Restart Claude Code for changes to take effect"
    Write-Host "  2. Customize CLAUDE.md for your specific projects"
    if (-not $doLark) {
        Write-Host "  3. Lark/Feishu MCP is off by default. To add it: claude mcp add --scope user --transport stdio lark-mcp -- npx -y `"@larksuiteoapi/lark-mcp`" mcp -a <APP_ID> -s <APP_SECRET>"
    }
    Write-Host ""
    Write-Info "GPT backend auto-configuration and the cl_gpt launcher are macOS/Linux only (bash/zsh). Windows has no cl_gpt runtime yet — see docs/BACKENDS.md."
}

# Import guard: when CLAUDE_CODE_CONFIG_IMPORT_ONLY=1, define functions/globals
# but do NOT invoke Main. Tests dot-source install.ps1 with this set (plus an
# isolated HOME/USERPROFILE/TMPDIR/TMP/TEMP) so the installer never executes.
if (-not $env:CLAUDE_CODE_CONFIG_IMPORT_ONLY) { Main }
} @_safeArgs
