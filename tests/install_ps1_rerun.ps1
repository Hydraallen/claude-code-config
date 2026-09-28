# Unit checks for install.ps1's re-run semantics (detection, deselect removal,
# retired mattpocock sweep, selection record). Run by
# tests/test_install_ps1_rerun.py when pwsh is available:
#   ACCC_SRC=<repo> ACCC_WORK=<empty dir> BASH_DIGEST_DIR=... BASH_DIGEST_FILE=... pwsh -File tests/install_ps1_rerun.ps1
$ErrorActionPreference = "Stop"
$env:CLAUDE_CODE_CONFIG_IMPORT_ONLY = "1"
$src = $env:ACCC_SRC
$work = $env:ACCC_WORK
$home2 = Join-Path $work "home"
$env:USERPROFILE = $home2
New-Item -ItemType Directory -Path "$home2/.claude" -Force | Out-Null
$text = Get-Content $src/install.ps1 -Raw
$start = $text.IndexOf("`n& {`n") + 1
$end = $text.LastIndexOf("} @_safeArgs")
$body = $text.Substring($start + 3, $end - $start - 3)
$sb = [scriptblock]::Create($body)
. $sb
$script:SCRIPT_DIR = $src
$fail = 0
function Check($name, $cond) { if ($cond) { Write-Host "PASS $name" } else { Write-Host "FAIL $name"; $script:fail++ } }

# 1. tree digest parity with bash (value computed by bash passed in env)
Check "tree digest parity (dir)" ((Get-TreeDigest -Path "$src/platforms/claude/templates/rules/python") -eq $env:BASH_DIGEST_DIR)
Check "tree digest parity (file)" ((Get-TreeDigest -Path "$src/platforms/claude/templates/rules/writing-style.md") -eq $env:BASH_DIGEST_FILE)

# 2. Remove-OwnedPath: unmodified vs modified
$C = "$home2/.claude"
New-Item -ItemType Directory -Path "$C/rules" -Force | Out-Null
Copy-Item -Recurse "$src/platforms/claude/templates/rules/python" "$C/rules/python"
Copy-Item -Recurse "$src/platforms/claude/templates/rules/typescript" "$C/rules/typescript"
Save-OwnedPath -Rel "rules/python"
Add-Content -LiteralPath "$C/rules/typescript/coding-style.md" -Value "local edit"
Remove-OwnedPath -Rel "rules/python" -Source "$src/platforms/claude/templates/rules/python" -Label "python rules"
Remove-OwnedPath -Rel "rules/typescript" -Source "$src/platforms/claude/templates/rules/typescript" -Label "typescript rules"
Check "unmodified removed" (-not (Test-Path "$C/rules/python"))
Check "modified removed" (-not (Test-Path "$C/rules/typescript"))
$bk = @(Get-ChildItem "$C/agent-config/backups" -Directory)
Check "one backup dir" ($bk.Count -eq 1)
Check "modified backed up" ((Get-Content -Raw (Join-Path $bk[0].FullName "rules/typescript/coding-style.md")) -match "local edit")
Check "unmodified not backed up" (-not (Test-Path (Join-Path $bk[0].FullName "rules/python")))
Check "manifest forgot" (-not ((Get-Content -Raw "$C/agent-config/script-owned.tsv") -match "rules/python"))

# 3. settings edits
$settings = @{
  statusLine = @{ type = "command"; command = 'bash "${CLAUDE_CONFIG_DIR:-${USERPROFILE:-$HOME}/.claude}/hooks/statusline.sh"' }
  hooks = @{ SessionStart = @(
     @{ matcher = "startup"; hooks = @(@{ type = "command"; command = 'LESSONS_FILE=x; cat' }) },
     @{ matcher = "resume"; hooks = @(@{ type = "command"; command = 'echo mine' }) }
  ) }
  includeCoAuthoredBy = $true
} | ConvertTo-Json -Depth 10
Set-Content -LiteralPath "$C/settings.json" -Value $settings
New-Item -ItemType Directory -Path "$C/hooks" -Force | Out-Null
Copy-Item "$src/platforms/claude/templates/hooks/statusline.sh" "$C/hooks/statusline.sh"
Check "detect statusline" (Test-MenuItemInstalled -Id "statusline")
Check "detect lessons" (Test-MenuItemInstalled -Id "lessons")
Remove-DeselectedStatusLine
Remove-DeselectedLessonsHook
$s = Get-Content -Raw "$C/settings.json" | ConvertFrom-Json
Check "statusLine removed" (-not $s.PSObject.Properties['statusLine'])
Check "lessons hook removed, other kept" (@($s.hooks.SessionStart).Count -eq 1 -and $s.hooks.SessionStart[0].matcher -eq "resume")
Check "statusline.sh removed" (-not (Test-Path "$C/hooks/statusline.sh"))
Check "detect statusline after" (-not (Test-MenuItemInstalled -Id "statusline"))

# 4. MCP ownership
$cfg = @{ mcpServers = @{
  "lark-mcp" = @{ type = "stdio"; command = "npx"; args = @("-y", "@larksuiteoapi/lark-mcp", "mcp") }
  "playwright" = @{ type = "stdio"; command = "node"; args = @("/x.js") }
} } | ConvertTo-Json -Depth 10
Set-Content -LiteralPath "$home2/.claude.json" -Value $cfg
Check "lark ours" (Test-McpOurs -Name "lark-mcp")
Check "playwright not ours" (-not (Test-McpOurs -Name "playwright"))
Check "detect mcp-lark" (Test-MenuItemInstalled -Id "mcp-lark")
Check "detect mcp off" (-not (Test-MenuItemInstalled -Id "mcp"))

# 5. Retired mattpocock sweep
New-Item -ItemType Directory -Path "$C/skills/grilling","$C/skills/old-one","$C/skills/old-mod","$C/skills/legacy" -Force | Out-Null
"g" | Set-Content "$C/skills/grilling/SKILL.md"; "o" | Set-Content "$C/skills/old-one/SKILL.md"; "m" | Set-Content "$C/skills/old-mod/SKILL.md"; "l" | Set-Content "$C/skills/legacy/SKILL.md"
$h = { param($p) (Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash.ToLowerInvariant() }
$gh = & $h "$C/skills/grilling/SKILL.md"; $oh = & $h "$C/skills/old-one/SKILL.md"
[IO.File]::WriteAllText("$C/.mattpocock-skills", "grilling`t$gh`nold-one`t$oh`nold-mod`tdeadbeef`nlegacy`n")
"edited" | Set-Content "$C/skills/grilling/SKILL.md"
Remove-RetiredMattpocockSkills
Check "kept skill survives" (Test-Path "$C/skills/grilling")
Check "retired unmodified removed" (-not (Test-Path "$C/skills/old-one"))
Check "retired modified preserved" (Test-Path "$C/skills/old-mod")
Check "legacy v1 removed" (-not (Test-Path "$C/skills/legacy"))
$m = Get-Content -Raw "$C/.mattpocock-skills"
Check "manifest keeps install-time digest" ($m -eq "grilling`t$gh`n")

# 6. initial state with previous deselected record
New-Item -ItemType Directory -Path "$C/agent-config" -Force | Out-Null
'{"script_installer":{"deselected":["claude-md","skill-paper-reading"]}}' | Set-Content "$C/agent-config/selection.json"
"x" | Set-Content "$C/CLAUDE.md"
$script:PrevDeselectedIds = @(Get-PreviousDeselectedIds)
Check "kept-on-deselect honours record" (-not (Get-MenuInitialState -Id "claude-md" -Default $true))
Check "not installed + prev off" (-not (Get-MenuInitialState -Id "skill-paper-reading" -Default $true))
Check "not installed + default" (Get-MenuInitialState -Id "skill-cheatsheet-creator" -Default $true)
Check "installed wins" (Get-MenuInitialState -Id "mcp-lark" -Default $false)

# 7. menu test hook + selection record
$env:ACCC_TEST_MENU_IDS = "claude-md,rules-python"
$env:ACCC_TEST_MENU_STATE_OUT = (Join-Path $work "state.txt")
$r = Show-InteractiveMenu
Check "hook selection" ($r.ClaudeMd -and ($r.RuleLangs -contains "python") -and -not $r.Settings -and $r.FullSelection)
Check "hook dump" ((Get-Content -Raw (Join-Path $work "state.txt")) -match "mcp-lark=1")
Check "deselected recorded" ($script:MenuDeselectedIds -contains "settings" -and $script:MenuDeselectedIds -notcontains "claude-md")
Write-SelectionRecord -EffectiveIds @("claude-md", "rules-python") -Mode "interactive"
$sel = Get-Content -Raw "$C/agent-config/selection.json" | ConvertFrom-Json
Check "selection deselected" (@($sel.script_installer.deselected) -contains "settings")
Write-SelectionRecord -EffectiveIds @("settings") -Mode "only"
$sel = Get-Content -Raw "$C/agent-config/selection.json" | ConvertFrom-Json
Check "only drops installed id" ((@($sel.script_installer.deselected) -notcontains "settings") -and (@($sel.script_installer.deselected) -contains "mcp"))
Check "only keeps records" ($sel.items.PSObject.Properties.Name -contains "rules-python")
if ($fail -gt 0) { exit 1 }
