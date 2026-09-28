# Unit checks for install.ps1's retired-item leftover sweep
# (Remove-RetiredLeftovers): retired marketplace caches / data dirs / stale
# clones, temp_git_* age gate, ~/.claude-mem gates, ~/.claude.json usage
# records. Run by tests/test_install_ps1_retired_leftovers.py when pwsh is
# available:
#   ACCC_SRC=<repo> ACCC_WORK=<empty dir> pwsh -File tests/install_ps1_retired_leftovers.ps1
$ErrorActionPreference = "Stop"
$env:CLAUDE_CODE_CONFIG_IMPORT_ONLY = "1"
$src = $env:ACCC_SRC
$work = $env:ACCC_WORK
$text = Get-Content $src/install.ps1 -Raw
$start = $text.IndexOf("`n& {`n") + 1
$end = $text.LastIndexOf("} @_safeArgs")
$body = $text.Substring($start + 3, $end - $start - 3)
$fail = 0
function Check($name, $cond) { if ($cond) { Write-Host "PASS $name" } else { Write-Host "FAIL $name"; $script:fail++ } }

# Fresh HOME per scenario; re-dot-source so $CLAUDE_DIR follows USERPROFILE.
$script:n = 0
function New-Home {
    $script:n++
    $h = Join-Path $work "home$($script:n)"
    New-Item -ItemType Directory -Path "$h/.claude/plugins" -Force | Out-Null
    $env:USERPROFILE = $h
    return $h
}
$sb = [scriptblock]::Create($body)
# Called right after each top-level `. $sb` (dot-sourcing inside a function
# would scope the installer's functions to that function).
function Set-Fakes {
    $script:SCRIPT_DIR = $src
    # No real claude-mem process on the test machine may influence the checks.
    function script:Test-ClaudeMemRunning { return [bool]$script:FakeRunning }
}
function Put($path, $content = "x") { New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null; Set-Content -LiteralPath $path -Value $content }
function Installed($h, [string[]]$keys) {
    $p = @{}; foreach ($k in $keys) { $p[$k] = @(@{ scope = "user" }) }
    @{ version = 2; plugins = $p } | ConvertTo-Json -Depth 5 | Set-Content "$h/.claude/plugins/installed_plugins.json"
}
function Age($path, $minutes) {
    $t = (Get-Date).AddMinutes(-$minutes)
    Get-ChildItem -LiteralPath $path -Recurse -Force | ForEach-Object { $_.LastWriteTime = $t }
    (Get-Item -LiteralPath $path).LastWriteTime = $t
}
$cfgJson = @'
{
  "oauthAccount": {"emailAddress": "someone@example.com"},
  "firstStartTime": "2025-06-01T10:20:30.000Z",
  "projects": {"/work/claude-mem": {"history": [{"display": "claude-mem:smart-explore"}]}},
  "mcpServers": {"claude-mem": {"command": "x"}},
  "skillUsage": {
    "claude-mem:smart-explore": {"usageCount": 4},
    "everything-claude-code:configure-ecc": {"usageCount": 1},
    "pua:pua": {"usageCount": 2},
    "ecc:plan": {"usageCount": 9},
    "my-claude-mem-notes": {"usageCount": 1}
  },
  "pluginUsage": {
    "claude-mem@thedotmack": {"usageCount": 7},
    "other@thedotmack": {"usageCount": 1},
    "ecc@ecc": {"usageCount": 3},
    "claude-mem-lite@someone": {"usageCount": 1}
  }
}
'@

# 1. Retired marketplace caches, stale clone and data dir removed; current kept.
$h = New-Home; . $sb; Set-Fakes; $DryRun = $false; $script:FakeRunning = $false
$P = "$h/.claude/plugins"
Put "$P/cache/thedotmack/claude-mem/10.0.0/big.bin"
Put "$P/cache/pua-skills/pua/1.0/SKILL.md"
Put "$P/cache/ecc/ecc/2.0/SKILL.md"
Put "$P/marketplaces/thedotmack/README.md"
Put "$P/marketplaces/claude-health/README.md"
'{"claude-health": {"source": {}}}' | Set-Content "$P/known_marketplaces.json"
New-Item -ItemType Directory -Path "$P/data/claude-mem-thedotmack" -Force | Out-Null
Put "$P/data/ecc-ecc/state.json"
Installed $h @("ecc@ecc")
Remove-RetiredLeftovers
Check "retired cache removed" (-not (Test-Path "$P/cache/thedotmack"))
Check "retired pua cache removed" (-not (Test-Path "$P/cache/pua-skills"))
Check "current cache kept" (Test-Path "$P/cache/ecc/ecc/2.0/SKILL.md")
Check "stale unregistered clone removed" (-not (Test-Path "$P/marketplaces/thedotmack"))
Check "registered clone left to CLI" (Test-Path "$P/marketplaces/claude-health/README.md")
Check "retired data dir removed" (-not (Test-Path "$P/data/claude-mem-thedotmack"))
Check "current data dir kept" (Test-Path "$P/data/ecc-ecc/state.json")

# 2. Retired marketplace still used by an installed plugin: kept.
$h = New-Home; . $sb; Set-Fakes; $DryRun = $false
$P = "$h/.claude/plugins"
Put "$P/cache/thedotmack/claude-mem/1/x"
New-Item -ItemType Directory -Path "$P/data/claude-mem-thedotmack" -Force | Out-Null
Installed $h @("claude-mem@thedotmack")
Remove-RetiredLeftovers
Check "in-use retired cache kept" (Test-Path "$P/cache/thedotmack/claude-mem/1/x")
Check "in-use data dir kept" (Test-Path "$P/data/claude-mem-thedotmack")

# 3. Unreadable installed_plugins.json: nothing deleted.
$h = New-Home; . $sb; Set-Fakes; $DryRun = $false; $script:FakeRunning = $false
$P = "$h/.claude/plugins"
Put "$P/cache/thedotmack/claude-mem/1/x"
Put "$h/.claude-mem/db"
"{not json" | Set-Content "$P/installed_plugins.json"
Remove-RetiredLeftovers
Check "unreadable state keeps cache" (Test-Path "$P/cache/thedotmack/claude-mem/1/x")
Check "unreadable state keeps claude-mem data" (Test-Path "$h/.claude-mem/db")

# 4. temp_git_* age gate.
$h = New-Home; . $sb; Set-Fakes; $DryRun = $false
$P = "$h/.claude/plugins"
Put "$P/cache/temp_git_1/repo/f"; Age "$P/cache/temp_git_1" 180
Put "$P/cache/temp_git_2/repo/f"; Age "$P/cache/temp_git_2" 10
Put "$P/cache/temp_git_3/repo/old"; Age "$P/cache/temp_git_3" 180; Put "$P/cache/temp_git_3/repo/fresh"
Remove-RetiredLeftovers
Check "old temp_git removed" (-not (Test-Path "$P/cache/temp_git_1"))
Check "young temp_git kept" (Test-Path "$P/cache/temp_git_2/repo/f")
Check "temp_git with fresh content kept" (Test-Path "$P/cache/temp_git_3/repo/old")

# 5. ~/.claude-mem gates.
$h = New-Home; . $sb; Set-Fakes; $DryRun = $false
Put "$h/.claude-mem/db"
$script:FakeRunning = $true; Remove-RetiredLeftovers
Check "claude-mem data kept while running" (Test-Path "$h/.claude-mem/db")
$script:FakeRunning = $false; Installed $h @("claude-mem@fork"); Remove-RetiredLeftovers
Check "claude-mem data kept while plugin installed" (Test-Path "$h/.claude-mem/db")
Installed $h @(); $env:ACCC_KEEP_CLAUDE_MEM_DATA = "1"; Remove-RetiredLeftovers; Remove-Item Env:ACCC_KEEP_CLAUDE_MEM_DATA
Check "claude-mem data kept when opted out" (Test-Path "$h/.claude-mem/db")
Remove-RetiredLeftovers
Check "claude-mem data removed when retired and idle" (-not (Test-Path "$h/.claude-mem"))

# 6. ~/.claude.json usage records.
$h = New-Home; . $sb; Set-Fakes; $DryRun = $false
Set-Content -LiteralPath "$h/.claude.json" -Value $cfgJson -NoNewline
Installed $h @("ecc@ecc")
Remove-RetiredLeftovers
$after = Get-Content -Raw "$h/.claude.json" | ConvertFrom-Json -AsHashtable
Check "skillUsage pruned" ((@($after.skillUsage.Keys) | Sort-Object) -join "," -eq "ecc:plan,my-claude-mem-notes")
Check "pluginUsage pruned" ((@($after.pluginUsage.Keys) | Sort-Object) -join "," -eq "claude-mem-lite@someone,ecc@ecc")
$raw = Get-Content -Raw "$h/.claude.json"
Check "date string preserved verbatim" ($raw -match '"firstStartTime": "2025-06-01T10:20:30.000Z"')
Check "projects untouched" ($after.projects["/work/claude-mem"].history[0].display -eq "claude-mem:smart-explore")
Check "mcpServers untouched" ($after.mcpServers.ContainsKey("claude-mem"))
Check "oauth untouched" ($after.oauthAccount.emailAddress -eq "someone@example.com")
$baks = @(Get-ChildItem -LiteralPath $h -Force -Filter ".claude.json.*.bak")
Check "one backup" ($baks.Count -eq 1 -and (Get-Content -Raw $baks[0].FullName) -eq $cfgJson)
Start-Sleep -Seconds 1.1
Remove-RetiredLeftovers
Check "no backup when unchanged" (@(Get-ChildItem -LiteralPath $h -Force -Filter ".claude.json.*.bak").Count -eq 1)

# 7. Records of a still-installed retired plugin are kept; invalid JSON untouched.
$h = New-Home; . $sb; Set-Fakes; $DryRun = $false
Set-Content -LiteralPath "$h/.claude.json" -Value $cfgJson -NoNewline
Installed $h @("claude-mem@thedotmack")
Remove-RetiredLeftovers
$after = Get-Content -Raw "$h/.claude.json" | ConvertFrom-Json -AsHashtable
Check "installed plugin records kept" ($after.skillUsage.ContainsKey("claude-mem:smart-explore") -and $after.pluginUsage.ContainsKey("other@thedotmack"))
Check "other retired records removed" (-not $after.skillUsage.ContainsKey("pua:pua"))
$h = New-Home; . $sb; Set-Fakes; $DryRun = $false
Set-Content -LiteralPath "$h/.claude.json" -Value '{"skillUsage": {"claude-mem:x": 1}' -NoNewline
Remove-RetiredLeftovers
Check "invalid json untouched" ((Get-Content -Raw "$h/.claude.json") -eq '{"skillUsage": {"claude-mem:x": 1}')
Check "invalid json no backup" (@(Get-ChildItem -LiteralPath $h -Force -Filter ".claude.json.*.bak").Count -eq 0)

# 8. Dry run previews with sizes and changes nothing.
$h = New-Home; . $sb; Set-Fakes; $DryRun = $true; $script:FakeRunning = $false
$P = "$h/.claude/plugins"
Put "$P/cache/thedotmack/claude-mem/1/x" ("y" * 5000)
Put "$h/.claude-mem/db"
Put "$P/cache/temp_git_9/f"; Age "$P/cache/temp_git_9" 120
Set-Content -LiteralPath "$h/.claude.json" -Value $cfgJson -NoNewline
Installed $h @("ecc@ecc")
$out = Remove-RetiredLeftovers 6>&1 | Out-String
Check "dry: cache kept" (Test-Path "$P/cache/thedotmack/claude-mem/1/x")
Check "dry: temp kept" (Test-Path "$P/cache/temp_git_9/f")
Check "dry: claude-mem kept" (Test-Path "$h/.claude-mem/db")
Check "dry: json unchanged" ((Get-Content -Raw "$h/.claude.json") -eq $cfgJson)
Check "dry: preview cache with size" ($out -match 'Would remove retired marketplace plugin cache: .*thedotmack \(4 KB\)')
Check "dry: preview temp" ($out -match 'Would remove stale plugin temp clone')
Check "dry: preview claude-mem" ($out -match 'Would remove retired claude-mem data')
Check "dry: preview skillUsage" ($out -match [regex]::Escape('skillUsage[claude-mem:smart-explore]'))
Check "dry: preview pluginUsage" ($out -match [regex]::Escape('pluginUsage[claude-mem@thedotmack]'))
Check "dry: summary" ($out -match 'Retired leftovers: would remove 3 path\(s\)')

if ($fail -gt 0) { Write-Host "$fail check(s) failed"; exit 1 }
Write-Host "all retired-leftover checks passed"
