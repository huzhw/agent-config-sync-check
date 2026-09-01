#Requires -Version 5.1
<#
.SYNOPSIS
  agent-config-sync-check - sync guard core script (4 agent ends + skill repo)
.DESCRIPTION
  Checks sync integrity between the skill repo (F:\idea-workspase-skills) and
  4 agent home dirs (Claude Code / DSH / Codex / ZCode):
    1. Junction skill links coverage (repo SKILL.md frontmatter = single source of truth)
    2. Dangling links pointing into the repo
    3. Global rules hardlink group (CLAUDE.md / AGENTS.md x4)
    4. SKILL.md frontmatter sanity (name/description, kebab-case)
    5. Repo root README skill-list section (BEGIN/END marks, auto-maintained)
    6. Redline dirs (coding-rules must never be linked)
  Runtime: Windows PowerShell 5.1 compatible (no pwsh 7 on this box; junctions via mklink /J).
  IMPORTANT: this script source is ASCII-only ON PURPOSE. The host is PS 5.1 and
  editors may save files as UTF-8 WITHOUT BOM, which 5.1 decodes as ANSI - any
  non-ASCII literal in source would corrupt parsing. Chinese texts live in
  sync-config.json (read at runtime as UTF-8) or come from Unicode code points.
  The AI running this skill translates the English report into Chinese for the user.
.PARAMETER Fix
  Fix mode: auto-repair mechanical issues (create missing junctions, remove dangling
  links non-recursively, regenerate README section).
.PARAMETER Quiet
  Scheduled-task mode: console shows summary only, log is still written.
.PARAMETER ConfigPath
  Config file path. Defaults to sync-config.json next to the script's parent dir.
.EXAMPLE
  powershell -NoProfile -File sync-check.ps1            # read-only check
  powershell -NoProfile -File sync-check.ps1 -Fix       # check + auto repair
  powershell -NoProfile -File sync-check.ps1 -Quiet     # scheduled task
#>
param(
    [switch]$Fix,
    [switch]$Quiet,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
$script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ConfigPath) {
    $ConfigPath = Join-Path (Split-Path -Parent $script:ScriptDir) 'sync-config.json'
}
$script:LogDir = Join-Path (Split-Path -Parent $script:ScriptDir) 'logs'
$script:Fixed = 0

# ---------- helpers ----------

# Normalize path for case-insensitive compare (lowercase, trim trailing slash)
function Normalize-Path {
    param([string]$p)
    if ([string]::IsNullOrWhiteSpace($p)) { return '' }
    try {
        return ([IO.Path]::GetFullPath($p)).TrimEnd('\').ToLowerInvariant()
    } catch {
        return $p.TrimEnd('\').ToLowerInvariant()
    }
}

# Junction target (Target may be an array on some hosts)
function Get-LinkTarget {
    param($item)
    $t = $item.Target
    if ($t -is [array]) { $t = $t[0] }
    return [string]$t
}

# Issue collector
$script:Issues = [System.Collections.Generic.List[object]]::new()
function Add-Issue {
    param(
        [string]$Agent, [string]$Level, [string]$Type, [string]$Detail,
        [bool]$Fixable,
        [string]$LinkName = '', [string]$LinkPath = '', [string]$ExpectedDir = ''
    )
    $script:Issues.Add([pscustomobject]@{
        Agent       = $Agent; Level = $Level; Type = $Type; Detail = $Detail
        Fixable     = $Fixable; LinkName = $LinkName; LinkPath = $LinkPath; ExpectedDir = $ExpectedDir
    })
}

# Write / append files as UTF-8 WITHOUT BOM
# (PS 5.1 "-Encoding UTF8" writes a BOM; we want clean UTF-8 for web-style files)
function Write-NoBomUtf8 {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}
function Append-NoBomUtf8 {
    param([string]$Path, [string]$Text)
    [IO.File]::AppendAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

# ---------- skill discovery (truth = repo SKILL.md frontmatter) ----------

function Find-ExpectedSkills {
    param([string]$Repo, [string[]]$ExcludeDirs)
    $escaped = ($ExcludeDirs | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $excludeRegex = '\\(' + $escaped + ')\\'
    $expected = @{}
    $frontmatterIssues = @()

    Get-ChildItem -LiteralPath $Repo -Recurse -Filter 'SKILL.md' -Force |
        Where-Object { $_.FullName -notmatch $excludeRegex } |
        ForEach-Object {
            $file = $_.FullName
            $lines = Get-Content -LiteralPath $file -Encoding UTF8
            if ($lines.Count -lt 3 -or $lines[0].Trim() -ne '---') {
                $frontmatterIssues += "frontmatter missing: $file"; return
            }
            $endIdx = -1
            for ($i = 1; $i -lt $lines.Count; $i++) {
                if ($lines[$i].Trim() -eq '---') { $endIdx = $i; break }
            }
            if ($endIdx -lt 0) { $frontmatterIssues += "frontmatter not closed: $file"; return }
            $fm = $lines[1..($endIdx - 1)]
            $nameLine = $fm | Where-Object { $_ -match '^name:\s*(\S.*?)\s*$' } | Select-Object -First 1
            $descLine = $fm | Where-Object { $_ -match '^description:\s*(\S.*?)\s*$' } | Select-Object -First 1
            if (-not $nameLine) { $frontmatterIssues += "name missing: $file"; return }
            if (-not $descLine) { $frontmatterIssues += "description missing: $file"; return }
            $name = ($nameLine -replace '^name:\s*', '').Trim()
            $desc = ($descLine -replace '^description:\s*', '').Trim()
            if ($name -notmatch '^[a-z0-9]+(-[a-z0-9]+)*$') {
                $frontmatterIssues += "name not lowercase kebab-case: '$name' ($file)"; return
            }
            if ($expected.ContainsKey($name)) {
                $frontmatterIssues += "duplicate name: '$name'"; return
            }
            $expected[$name] = @{ Dir = $_.DirectoryName; Description = $desc }
        }
    return @{ Expected = $expected; FrontmatterIssues = $frontmatterIssues }
}

# ---------- checks 1 + 2 + 6: link coverage / dangling / redline ----------

function Test-AgentLinks {
    param([object]$Agent, [hashtable]$Expected, [string]$Repo, [string[]]$RedlineDirs)

    $aName = $Agent.name
    $skillsDir = Join-Path $Agent.home 'skills'
    $nRepo = Normalize-Path $Repo

    # 1. forward: every expected skill must have a correct junction in skills\
    foreach ($k in $Expected.Keys) {
        $dir = $Expected[$k].Dir
        $lp = Join-Path $skillsDir $k
        $item = Get-Item -LiteralPath $lp -Force -ErrorAction SilentlyContinue
        if (-not $item) {
            Add-Issue $aName 'ERROR' 'MissingLink' "skills\$k does not exist (repo dir: $dir)" $true -LinkName $k -LinkPath $lp -ExpectedDir $dir
            continue
        }
        if ($item.LinkType -ne 'Junction') {
            Add-Issue $aName 'ERROR' 'NotJunction' "skills\$k exists but is not a junction (LinkType=$($item.LinkType)); needs manual review" $false
            continue
        }
        $tgt = Get-LinkTarget $item
        if ((Normalize-Path $tgt) -ne (Normalize-Path $dir)) {
            Add-Issue $aName 'ERROR' 'WrongTarget' "skills\$k -> $tgt (expected: $dir)" $true -LinkName $k -LinkPath $lp -ExpectedDir $dir
            continue
        }
        if (-not (Test-Path -LiteralPath $lp)) {
            Add-Issue $aName 'ERROR' 'BrokenLink' "skills\$k target not reachable" $true -LinkName $k -LinkPath $lp -ExpectedDir $dir
        }
    }

    # 2. reverse: every junction under skills\ pointing into the repo must be in the
    #    expected set and its target must exist; relay links only need target alive
    if (-not (Test-Path -LiteralPath $skillsDir)) {
        Add-Issue $aName 'ERROR' 'SkillsDirMissing' "$skillsDir does not exist" $false
        return
    }
    foreach ($e in (Get-ChildItem -LiteralPath $skillsDir -Force)) {
        if ($e.LinkType -ne 'Junction') { continue }
        $tgt = Get-LinkTarget $e
        $nTgt = Normalize-Path $tgt
        if ($nTgt -eq $nRepo -or $nTgt -like "$nRepo\*") {
            # points into our repo: redline first
            foreach ($r in $RedlineDirs) {
                $nRed = Normalize-Path (Join-Path $Repo $r)
                if ($nTgt -eq $nRed -or $nTgt -like "$nRed\*") {
                    Add-Issue $aName 'ERROR' 'RedlineLink' "skills\$($e.Name) points to non-skill dir '$r' ($tgt); should be removed" $true -LinkName $e.Name -LinkPath $e.FullName
                }
            }
            if (-not (Test-Path -LiteralPath $tgt)) {
                Add-Issue $aName 'ERROR' 'DanglingLink' "skills\$($e.Name) -> $tgt (repo target deleted; remove the link)" $true -LinkName $e.Name -LinkPath $e.FullName
                continue
            }
            if (-not $Expected.ContainsKey($e.Name)) {
                Add-Issue $aName 'WARN' 'ExtraRepoLink' "skills\$($e.Name) -> $tgt (repo dir exists but not in skill set; rename residue?)" $true -LinkName $e.Name -LinkPath $e.FullName
            }
        } else {
            # relay link (.zcode -> .claude / .codex\.system): only check target alive
            if (-not (Test-Path -LiteralPath $tgt)) {
                Add-Issue $aName 'WARN' 'RelayDangling' "skills\$($e.Name) -> $tgt (upstream deleted; report only, no auto-fix)" $false
            }
        }
    }
}

# ---------- check 3: global rules hardlink group ----------
# Pure-cmdlet implementation: PS 5.1 (Get-Item).Target on a HardLink file returns
# a List<string> of the OTHER paths in the same hardlink group. No fsutil, no
# cmd.exe - immune to sandbox child-process flakiness.

function Test-RulesHardlink {
    param([object]$Cfg)
    if (-not $Cfg.rulesHardlink.enabled) { return }
    $paths = @($Cfg.rulesHardlink.paths)

    $items = @{}
    foreach ($p in $paths) {
        $item = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
        if (-not $item) { Add-Issue 'rules' 'ERROR' 'RulesFileMissing' $p $false; continue }
        $items[$p] = $item
        if ($item.LinkType -ne 'HardLink') {
            Add-Issue 'rules' 'ERROR' 'HardlinkBroken' "$p LinkType='$($item.LinkType)' (likely re-saved as standalone copy; 4-end rules sync is broken)" $false
            continue
        }
        if ($item.Length -le 0) { Add-Issue 'rules' 'ERROR' 'RulesFileEmpty' $p $false }
    }

    # same-group check: every pair must appear in each other's Target list (i<j only)
    $keys = @($items.Keys)
    for ($i = 0; $i -lt $keys.Count; $i++) {
        for ($j = $i + 1; $j -lt $keys.Count; $j++) {
            $a = $keys[$i]; $b = $keys[$j]
            $ia = $items[$a]; $ib = $items[$b]
            if ($ia.LinkType -ne 'HardLink' -or $ib.LinkType -ne 'HardLink') { continue }
            $aTargets = @($ia.Target | ForEach-Object { Normalize-Path ([string]$_) })
            $bTargets = @($ib.Target | ForEach-Object { Normalize-Path ([string]$_) })
            if (($aTargets -notcontains (Normalize-Path $b)) -or ($bTargets -notcontains (Normalize-Path $a))) {
                $info = "Size={0}/{1} MTime={2}/{3}" -f $ia.Length, $ib.Length,
                        $ia.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'),
                        $ib.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
                Add-Issue 'rules' 'ERROR' 'HardlinkGroupSplit' "$a and $b are NOT in the same hardlink group (content may have forked; decide which copy wins manually then rebuild hardlinks; $info)" $false
            }
        }
    }
}

# ---------- checks 9 + 10: ssh-mcp config junctions + per-end registration ----------
# The ssh-mcp TOML lives in assets\ssh-mcp (repo); each agent home gets a
# junction <home>\ssh-mcp -> that dir, and per-end MCP registration points
# --config into it. Passwords NEVER appear in this source: they are read at
# runtime from the password source file (see sync-config.json) and only
# written into the target config files.

function Get-SshCfg {
    param([object]$Cfg)
    if ($Cfg.PSObject.Properties.Name -contains 'sshMcpConfig') { return $Cfg.sshMcpConfig }
    return $null
}

function Test-SshMcpJunction {
    param([object]$Cfg)
    $c = Get-SshCfg $Cfg
    if (-not $c -or -not $c.enabled) { return }
    $srcDir = [string]$c.sourceDir
    $fileName = [string]$c.configFileName
    if (-not (Test-Path -LiteralPath (Join-Path $srcDir $fileName))) {
        Add-Issue 'ssh-mcp' 'ERROR' 'SshCfgSourceMissing' "source toml missing: $(Join-Path $srcDir $fileName) (restore manually; never auto-generate)" $false
        return
    }
    foreach ($endName in @($c.junctionEnds)) {
        $agent = $Cfg.agents | Where-Object { $_.name -eq $endName } | Select-Object -First 1
        if (-not $agent) { continue }
        $lp = Join-Path $agent.home 'ssh-mcp'
        $item = Get-Item -LiteralPath $lp -Force -ErrorAction SilentlyContinue
        if (-not $item) {
            Add-Issue 'ssh-mcp' 'ERROR' 'SshJunctionMissing' "$lp does not exist (expected junction to $srcDir)" $true -LinkName $endName -LinkPath $lp -ExpectedDir $srcDir
            continue
        }
        if ($item.LinkType -ne 'Junction') {
            Add-Issue 'ssh-mcp' 'ERROR' 'SshJunctionNotLink' "$lp exists but is not a junction (LinkType=$($item.LinkType)); manual review" $false
            continue
        }
        if ((Normalize-Path (Get-LinkTarget $item)) -ne (Normalize-Path $srcDir)) {
            Add-Issue 'ssh-mcp' 'ERROR' 'SshJunctionWrongTarget' "$lp -> $(Get-LinkTarget $item) (expected: $srcDir)" $true -LinkName $endName -LinkPath $lp -ExpectedDir $srcDir
            continue
        }
        if (-not (Test-Path -LiteralPath (Join-Path $lp $fileName))) {
            Add-Issue 'ssh-mcp' 'ERROR' 'SshJunctionBroken' "$lp target not reachable" $true -LinkName $endName -LinkPath $lp -ExpectedDir $srcDir
        }
    }
}

function Get-PasswordKeys {
    # Read KEY=VALUE lines (names only, never values) from the single passwords file.
    param([string]$File)
    $keys = @()
    foreach ($line in (Get-Content -LiteralPath $File -Encoding UTF8)) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=') { $keys += $Matches[1] }
    }
    return $keys
}

function Get-TomlProfileNames {
    param([string]$File)
    $names = @()
    foreach ($line in (Get-Content -LiteralPath $File -Encoding UTF8)) {
        if ($line -match '^\s*name\s*=\s*"([^"]+)"\s*$') { $names += $Matches[1] }
    }
    return $names
}

function Backup-ConfigFile {
    param([string]$File)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $bak = "$File.bak-sshmcp-$stamp"
    Copy-Item -LiteralPath $File -Destination $bak -Force
    return $bak
}

function Remove-SshRegistrationBlock {
    # Remove an existing registration block (legacy or launcher form).
    # dsh-patch: top-level "- insert:" whose child is "- id: mcp-<name>", until the
    #            next top-level "- " entry or EOF.
    # codex-toml: "[mcp_servers.<name>]" until the next "[" table header or EOF
    #             (covers the [mcp_servers.<name>.env] subtable too).
    param([string]$Type, [string]$File, [string]$Name)
    $text = Get-Content -LiteralPath $File -Raw -Encoding UTF8
    $lines = [System.Collections.Generic.List[string]](($text -split "`r?`n"))
    $remove = [System.Collections.Generic.List[int]]::new()
    if ($Type -eq 'dsh-patch') {
        return (Remove-McpDshChild -File $File -Id ("mcp-" + $Name))
    } else {
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match "^\[mcp_servers\.$name\]\s*$") {
                for ($j = $i; $j -lt $lines.Count; $j++) {
                    if ($j -gt $i -and $lines[$j] -match '^\[') { break }
                    $remove.Add($j)
                }
                break
            }
        }
    }
    if ($remove.Count -eq 0) { return $false }
    for ($i = $remove.Count - 1; $i -ge 0; $i--) { $lines.RemoveAt($remove[$i]) }
    while ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -match '^\s*$') { $lines.RemoveAt($lines.Count - 1) }
    Write-NoBomUtf8 -Path $File -Text (($lines -join "`r`n") + "`r`n")
    return $true
}

function Add-SshRegistration {
    # Install (or migrate) the launcher-form registration: no passwords in the
    # registration block - ssh-mcp reads them from ssh-passwords.env via launcher.js.
    param([object]$Cfg, [string]$EndName)
    $c = (Get-SshCfg $Cfg).registration
    $endProp = $c.ends.PSObject.Properties[$EndName]
    if (-not $endProp) { throw "unknown ssh-mcp registration end: $EndName" }
    $end = $endProp.Value
    $file = [string]$end.file
    $cfgPath = [string]$end.configPath
    $launcher = [string]$end.launcherPath
    $name = [string]$c.serverName
    $bak = Backup-ConfigFile $file
    try {
        switch ([string]$end.type) {
            'dsh-patch' {
                Remove-SshRegistrationBlock -Type 'dsh-patch' -File $file -Name $name | Out-Null
                $nl = "`r`n"
                $block = $nl +
                    '- insert:' + $nl +
                    "  - id: mcp-$name" + $nl +
                    "    name: '@deepseek-ai/dsh-mcp-client'" + $nl +
                    '    config:' + $nl +
                    "      serverName: $name" + $nl +
                    '      transport: stdio' + $nl +
                    "      command: $([string]$c.command)" + $nl +
                    '      args:' + $nl +
                    "      - $launcher" + $nl +
                    "      - --config=$cfgPath" + $nl
                Append-NoBomUtf8 -Path $file -Text $block
                $code = "const fs=require('fs'),YAML=require(process.argv[2]);YAML.parse(fs.readFileSync(process.argv[1],'utf8'));console.log('YAML_OK')"
                $out = & node -e $code $file ([string]$c.yamlModulePath) 2>&1
                if (($out | Out-String) -notlike '*YAML_OK*') { throw "yaml validation failed after append: $out" }
            }
            'codex-toml' {
                Remove-SshRegistrationBlock -Type 'codex-toml' -File $file -Name $name | Out-Null
                $nl = "`r`n"
                $block = $nl +
                    "[mcp_servers.$name]" + $nl +
                    "command = `"$([string]$c.command)`"" + $nl +
                    "args = [`"$launcher`", `"--config=$cfgPath`"]" + $nl
                Append-NoBomUtf8 -Path $file -Text $block
                $py = [string]$c.pythonPath
                $code = "import tomllib,sys; tomllib.load(open(sys.argv[1],'rb')); print('TOML_OK')"
                $out = & $py -c $code $file 2>&1
                if (($out | Out-String) -notlike '*TOML_OK*') { throw "toml validation failed after append: $out" }
            }
            default { throw "unsupported registration type: $($end.type)" }
        }
        # backup is kept on purpose (*.bak-sshmcp-* never enters git)
    } catch {
        if ($bak -and (Test-Path -LiteralPath $bak)) {
            Copy-Item -LiteralPath $bak -Destination $file -Force
        }
        throw
    }
}

function Test-SshMcpRegistration {
    param([object]$Cfg)
    $c = Get-SshCfg $Cfg
    if (-not $c -or -not $c.enabled -or -not $c.registration) { return }
    $reg = $c.registration
    $name = [string]$reg.serverName
    $launcherName = [string]$reg.launcherName
    $command = [string]$reg.command

    # 10a. passwords file must exist and cover every toml profile
    $pwFile = [string]$reg.passwordsFile
    $toml = Join-Path ([string]$c.sourceDir) ([string]$c.configFileName)
    if (-not (Test-Path -LiteralPath $pwFile)) {
        Add-Issue 'ssh-mcp' 'ERROR' 'SshPasswordsMissing' "passwords file missing: $pwFile (contains secrets; never auto-generate - restore manually)" $false
    } elseif (Test-Path -LiteralPath $toml) {
        $pwKeys = Get-PasswordKeys $pwFile
        $missing = @()
        foreach ($pn in (Get-TomlProfileNames $toml)) {
            $need = 'SSH_MCP_' + ($pn.ToUpperInvariant()) + '_PASSWORD'
            if ($pwKeys -notcontains $need) { $missing += $need }
        }
        if ($missing.Count -gt 0) {
            Add-Issue 'ssh-mcp' 'ERROR' 'SshPasswordsIncomplete' "passwords file lacks keys: $($missing -join ', ') (a server profile has no password)" $false
        }
    }

    # 10b. per-end registration must be in the launcher form (password-free)
    foreach ($prop in $reg.ends.PSObject.Properties) {
        $endName = $prop.Name
        $end = $prop.Value
        $file = [string]$end.file
        $cfgPath = [string]$end.configPath
        $launcherPath = [string]$end.launcherPath
        $agent = "ssh-mcp/$endName"
        if (-not (Test-Path -LiteralPath $file)) {
            Add-Issue $agent 'ERROR' 'SshRegFileMissing' "registration target file missing: $file" $false
            continue
        }
        switch ([string]$end.type) {
            'claude-json' {
                $json = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
                if (-not $json.mcpServers) {
                    Add-Issue $agent 'ERROR' 'SshMcpNotRegistered' "no mcpServers at all in $file" ([bool]$end.fixable) -LinkName $endName
                    continue
                }
                $srvProp = $json.mcpServers.PSObject.Properties[$name]
                if (-not $srvProp) {
                    Add-Issue $agent 'ERROR' 'SshMcpNotRegistered' "mcpServers.$name missing in $file" ([bool]$end.fixable) -LinkName $endName
                    continue
                }
                $srv = $srvProp.Value
                if ([string]$srv.command -eq $command -and @($srv.args | ForEach-Object { [string]$_ }) -contains $launcherPath) {
                    $argsText = @($srv.args | ForEach-Object { [string]$_ }) -join ' '
                    if ($argsText -notlike "*--config=$cfgPath*") {
                        Add-Issue $agent 'ERROR' 'SshMcpStalePath' "ssh args point elsewhere: $argsText" $true -LinkName $endName
                    }
                    if ($srv.env -and @($srv.env.PSObject.Properties).Count -gt 0) {
                        Add-Issue $agent 'WARN' 'SshMcpLegacyEnv' "mcpServers.$name.env still carries values; launcher form needs no env" $false
                    }
                    continue
                }
                Add-Issue $agent 'ERROR' 'SshMcpLegacyRegistration' "mcpServers.$name is not in launcher form (command=$([string]$srv.command)) - passwords must live only in ssh-passwords.env" ([bool]$end.fixable) -LinkName $endName
            }
            'dsh-patch' {
                $text = Get-Content -LiteralPath $file -Raw -Encoding UTF8
                $blockStart = [regex]::Match($text, "(?ms)^- insert:\r?\n  - id: mcp-$name\s*$")
                if (-not $blockStart.Success) {
                    Add-Issue $agent 'ERROR' 'SshMcpNotRegistered' "no 'mcp-$name' insert block in $file" $true -LinkName $endName
                    continue
                }
                $secStart = $text.IndexOf($blockStart.Value)
                $nextTop = $text.IndexOf("`n- ", $secStart + 1)
                if ($nextTop -lt 0) { $nextTop = $text.Length }
                $blockText = $text.Substring($secStart, $nextTop - $secStart)
                if ($blockText -notlike "*$launcherName*") {
                    Add-Issue $agent 'ERROR' 'SshMcpLegacyRegistration' "mcp-$name block still spawns ssh-mcp directly (passwords inlined) - migrate to launcher form" $true -LinkName $endName
                    continue
                }
                if ($blockText -notlike "*--config=$cfgPath*") {
                    Add-Issue $agent 'WARN' 'SshMcpStalePath' "mcp-$name block points elsewhere (manual review)" $false
                }
            }
            'codex-toml' {
                $text = Get-Content -LiteralPath $file -Raw -Encoding UTF8
                $m = [regex]::Match($text, "(?m)^\[mcp_servers\.$name\]\s*$")
                if (-not $m.Success) {
                    Add-Issue $agent 'ERROR' 'SshMcpNotRegistered' "no [mcp_servers.$name] section in $file" $true -LinkName $endName
                    continue
                }
                $nextTop = $text.IndexOf("`n[", $m.Index + $m.Length)
                if ($nextTop -lt 0) { $nextTop = $text.Length }
                $blockText = $text.Substring($m.Index, $nextTop - $m.Index)
                if ($blockText -notlike "*$launcherName*") {
                    Add-Issue $agent 'ERROR' 'SshMcpLegacyRegistration' "[mcp_servers.$name] still spawns ssh-mcp directly (passwords inlined) - migrate to launcher form" $true -LinkName $endName
                    continue
                }
                if ($blockText -notlike "*--config=$cfgPath*") {
                    Add-Issue $agent 'WARN' 'SshMcpStalePath' "[mcp_servers.$name] points elsewhere (manual review)" $false
                }
            }
            default {
                Add-Issue $agent 'WARN' 'SshRegUnsupported' "registration type '$($end.type)' not supported (skipped)" $false
            }
        }
    }
}

# ---------- mcpSync: generic per-server registration sync (ssh-style flow) ----------
# Every server is declared in sync-config.json (mcpSync.servers) the same way
# sshMcpConfig declares ssh: expected command+args plus per-end registration
# targets. Check = parse the end files (node YAML / python tomllib) and compare
# command+args; fix = backup, remove old block, append canonical block,
# re-validate, roll back on failure. No passwords ever flow through here -
# servers that need env secrets must use the ssh launcher pattern instead.

function Get-McpSyncCfg {
    param([object]$Cfg)
    if ($Cfg.PSObject.Properties.Name -contains 'mcpSync') { return $Cfg.mcpSync }
    return $null
}

function Write-McpParserAssets {
    # Parser helpers as real files (PS 5.1 mangles inline code that embeds
    # double quotes when passing it to node/python on the command line).
    $js = Join-Path $script:LogDir 'parse-dsh.js'
    $py = Join-Path $script:LogDir 'parse-codex.py'
    Write-NoBomUtf8 -Path $js -Text @'
// usage: node parse-dsh.js <patch.yml> <yaml-module-path>
// (node argv: [0]=node, [1]=this script, [2]=patch file, [3]=yaml module)
const fs = require("fs");
const YAML = require(process.argv[3]);
const doc = YAML.parse(fs.readFileSync(process.argv[2], "utf8")) || [];
const found = {};
for (const item of doc) {
  if (item && item.insert) {
    for (const e of item.insert) {
      if (e && String(e.id || "").indexOf("mcp-") === 0) {
        found[String(e.id)] = {
          serverName: (e.config && e.config.serverName) ? String(e.config.serverName) : "",
          command: (e.config && e.config.command) ? String(e.config.command) : "",
          args: (e.config && e.config.args ? e.config.args : []).map(String)
        };
      }
    }
  }
}
console.log(JSON.stringify(found));
'@
    Write-NoBomUtf8 -Path $py -Text @'
import tomllib, sys, json
d = tomllib.load(open(sys.argv[1], "rb"))
ms = d.get("mcp_servers", {})
out = {}
for k, v in ms.items():
    out[k] = {"command": (v.get("command") or ""), "args": [str(a) for a in (v.get("args") or [])]}
print(json.dumps(out))
'@
    return @($js, $py)
}

function Get-McpParsedEnd {
    # Parse an end config file, return its mcp entries as PS object:
    # dsh-patch -> keyed by insert id (mcp-*), codex-toml -> keyed by server name.
    param([string]$Type, [string]$File)
    $assets = Write-McpParserAssets
    if ($Type -eq 'dsh-patch') {
        $out = & node $assets[0] $File ($script:McpYamlPath) 2>&1
        if ($LASTEXITCODE -ne 0) { throw "dsh patch parse failed: $out" }
        return ($out | ConvertFrom-Json)
    } else {
        $out = & ($script:McpPyPath) $assets[1] $File 2>&1
        if ($LASTEXITCODE -ne 0) { throw "codex toml parse failed: $out" }
        return ($out | ConvertFrom-Json)
    }
}

function ConvertTo-YamlArgLines {
    param([object]$ArgList, [string]$Indent)
    $out = @()
    if (-not $ArgList -or @($ArgList).Count -eq 0) { return $out }
    $out += "${Indent}args:"
    foreach ($a in @($ArgList)) {
        $v = [string]$a
        if ($v -match "[\s""']") { $out += "$Indent- '" + $v.Replace("'", "''") + "'" }
        else { $out += "$Indent- $v" }
    }
    return $out
}

function ConvertTo-TomlArgArray {
    param([object]$ArgList)
    $items = @()
    foreach ($a in @($ArgList)) {
        $v = ([string]$a).Replace('\', '\\').Replace('"', '\"')
        $items += '"' + $v + '"'
    }
    return ('[' + ($items -join ', ') + ']')
}

function Remove-McpDshChild {
    # Remove one "  - id: <id>" child (with its whole indented body) from the
    # dsh patch, wherever it lives (standalone or shared insert block). If the
    # wrapper "- insert:" becomes empty, drop it too.
    param([string]$File, [string]$Id)
    $text = Get-Content -LiteralPath $File -Raw -Encoding UTF8
    $lines = [System.Collections.Generic.List[string]](($text -split "`r?`n"))
    $idx = -1
    $idPat = '^\s{2}-\s*id:\s*' + [regex]::Escape($Id) + '\s*$'
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $idPat) { $idx = $i; break }
    }
    if ($idx -lt 0) { return $false }
    $endIdx = $lines.Count
    for ($j = $idx + 1; $j -lt $lines.Count; $j++) {
        if ($lines[$j] -match '^\s{2}-\s' -or $lines[$j] -match '^- ') { $endIdx = $j; break }
    }
    for ($j = $endIdx - 1; $j -ge $idx; $j--) { $lines.RemoveAt($j) }
    if ($idx -gt 0 -and $lines[$idx - 1] -eq '- insert:') {
        $n = $idx
        while ($n -lt $lines.Count -and $lines[$n] -match '^\s*$') { $n++ }
        if ($n -ge $lines.Count -or $lines[$n] -match '^- ') { $lines.RemoveAt($idx - 1) }
    }
    while ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -match '^\s*$') { $lines.RemoveAt($lines.Count - 1) }
    Write-NoBomUtf8 -Path $File -Text (($lines -join "`r`n") + "`r`n")
    return $true
}

function Test-McpSync {
    param([object]$Cfg)
    $c = Get-McpSyncCfg $Cfg
    if (-not $c -or -not $c.enabled) { return }
    $script:McpYamlPath = [string]$c.yamlModulePath
    $script:McpPyPath = [string]$c.pythonPath
    $parsed = @{}
    foreach ($srv in @($c.servers)) {
        foreach ($endName in @('dsh', 'codex')) {
            $endProp = $srv.PSObject.Properties[$endName]
            if (-not $endProp) { continue }
            $end = $endProp.Value
            $key = [string]$end.type + '|' + [string]$end.file
            if (-not $parsed.ContainsKey($key)) {
                if (-not (Test-Path -LiteralPath $end.file)) {
                    Add-Issue "mcp-sync/$($srv.name)/$endName" 'ERROR' 'McpFileMissing' "target file missing: $($end.file)" $false
                    $parsed[$key] = $null
                } else {
                    try { $parsed[$key] = Get-McpParsedEnd ([string]$end.type) ([string]$end.file) }
                    catch {
                        Add-Issue "mcp-sync/$($srv.name)/$endName" 'ERROR' 'McpParseFailed' ("{0}" -f $_.Exception.Message) $false
                        $parsed[$key] = $null
                    }
                }
            }
        }
    }
    foreach ($srv in @($c.servers)) {
        $name = [string]$srv.name
        $expCommand = [string]$srv.command
        $expArgs = @($srv.args | ForEach-Object { [string]$_ })
        foreach ($endName in @('dsh', 'codex')) {
            $endProp = $srv.PSObject.Properties[$endName]
            if (-not $endProp) { continue }
            $end = $endProp.Value
            $key = [string]$end.type + '|' + [string]$end.file
            if (-not $parsed[$key]) { continue }
            $agent = "mcp-sync/$name/$endName"
            $link = "$name|$endName"
            if ([string]$end.type -eq 'dsh-patch') {
                $e = $parsed[$key].PSObject.Properties[[string]$end.id]
                if (-not $e) {
                    Add-Issue $agent 'ERROR' 'McpMissing' "no '$($end.id)' insert entry in $($end.file)" $true -LinkName $link
                    continue
                }
                $got = $e.Value
                if ($got.serverName -ne $name) {
                    Add-Issue $agent 'ERROR' 'McpDrift' "'$($end.id)' serverName mismatch (got: $($got.serverName))" $true -LinkName $link
                    continue
                }
            } else {
                $e = $parsed[$key].PSObject.Properties[$name]
                if (-not $e) {
                    Add-Issue $agent 'ERROR' 'McpMissing' "no [mcp_servers.$name] section in $($end.file)" $true -LinkName $link
                    continue
                }
                $got = $e.Value
            }
            if ($got.command -ne $expCommand) {
                Add-Issue $agent 'ERROR' 'McpDrift' "command mismatch (got: $($got.command), want: $expCommand)" $true -LinkName $link
                continue
            }
            if ((@($got.args) -join "`n") -ne ($expArgs -join "`n")) {
                Add-Issue $agent 'ERROR' 'McpDrift' "args mismatch (got: $($got.args -join ' '))" $true -LinkName $link
            }
        }
    }
}

function Add-McpRegistration {
    # ssh-style repair: backup -> remove old block -> append canonical form ->
    # re-parse and verify -> roll back on any failure.
    param([object]$Cfg, [string]$ServerName, [string]$EndName)
    $c = Get-McpSyncCfg $Cfg
    $srv = @($c.servers | Where-Object { $_.name -eq $ServerName })[0]
    if (-not $srv) { throw "unknown mcp-sync server: $ServerName" }
    $end = $srv.PSObject.Properties[$EndName].Value
    $file = [string]$end.file
    $bak = Backup-ConfigFile $file
    try {
        if ([string]$end.type -eq 'dsh-patch') {
            Remove-McpDshChild -File $file -Id ([string]$end.id) | Out-Null
            $nl = "`r`n"
            $block = $nl +
                '- insert:' + $nl +
                "  - id: $($end.id)" + $nl +
                "    name: '$([string]$end.clientName)'" + $nl +
                '    config:' + $nl +
                "      serverName: $([string]$srv.name)" + $nl +
                '      transport: stdio' + $nl +
                "      command: $([string]$srv.command)" + $nl
            foreach ($l in (ConvertTo-YamlArgLines $srv.args '      ')) { $block += $l + $nl }
            Append-NoBomUtf8 -Path $file -Text $block
            $parsed = Get-McpParsedEnd 'dsh-patch' $file
            $e = $parsed.PSObject.Properties[[string]$end.id]
            if (-not $e) { throw "post-append verify failed: entry not found" }
            if ($e.Value.command -ne [string]$srv.command) { throw "post-append verify failed: command mismatch" }
        } else {
            Remove-SshRegistrationBlock -Type 'codex-toml' -File $file -Name ([string]$srv.name) | Out-Null
            $nl = "`r`n"
            $block = $nl +
                "[mcp_servers.$([string]$srv.name)]" + $nl +
                "command = `"$([string]$srv.command)`"" + $nl +
                "args = $(ConvertTo-TomlArgArray $srv.args)" + $nl
            Append-NoBomUtf8 -Path $file -Text $block
            $parsed = Get-McpParsedEnd 'codex-toml' $file
            $e = $parsed.PSObject.Properties[[string]$srv.name]
            if (-not $e) { throw "post-append verify failed: section not found" }
            if ($e.Value.command -ne [string]$srv.command) { throw "post-append verify failed: command mismatch" }
        }
        # backup is kept on purpose (*.bak-sshmcp-* never enters git)
    } catch {
        if ($bak -and (Test-Path -LiteralPath $bak)) {
            Copy-Item -LiteralPath $bak -Destination $file -Force
        }
        throw
    }
}

# ---------- check 5: repo root README skill-list section ----------

# Chinese full stop as Unicode code point (source must stay ASCII)
$script:CnFullStop = [string][char]0x3002

function Get-FirstSentence {
    param([string]$desc, [string]$Ellipsis)
    $d = $desc.Trim()
    $idx = $d.IndexOf($script:CnFullStop)
    if ($idx -ge 0 -and $idx -lt 40) { return $d.Substring(0, $idx + 1) }
    if ($d.Length -gt 60) { return $d.Substring(0, 57) + $Ellipsis }
    return $d
}

function New-SkillsSection {
    param([object]$Cfg, [hashtable]$Expected)
    # section title text (Chinese) comes from config, read at runtime as UTF-8
    $title = [string]$Cfg.readme.sectionTitle
    if (-not $title) { $title = '## Skills ({N}, auto-maintained by agent-config-sync-check, do not edit this block)' }
    $title = $title.Replace('{N}', [string]$Expected.Count)
    $ellipsis = [string][char]0x2026   # ...
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine()
    [void]$sb.AppendLine($title)
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('| # | Skill | Desc |')
    [void]$sb.AppendLine('|---|---|---|')
    $i = 1
    foreach ($name in ($Expected.Keys | Sort-Object)) {
        $desc = Get-FirstSentence $Expected[$name].Description $ellipsis
        [void]$sb.AppendLine("| $i | ``$name`` | $desc |")
        $i++
    }
    [void]$sb.AppendLine()
    return $sb.ToString()
}

function Test-Readme {
    param([object]$Cfg, [hashtable]$Expected)
    if (-not $Cfg.readme.enabled) { return }
    $p = $Cfg.readme.path
    $begin = $Cfg.readme.beginMark
    $end = $Cfg.readme.endMark
    if (-not (Test-Path -LiteralPath $p)) {
        Add-Issue 'README' 'ERROR' 'ReadmeMissing' "$p does not exist" $true
        return
    }
    $content = Get-Content -LiteralPath $p -Raw -Encoding UTF8
    if ($content -notlike "*$begin*" -or $content -notlike "*$end*") {
        Add-Issue 'README' 'ERROR' 'ReadmeMarkMissing' "README exists but skill-list marks are missing ($begin / $end)" $true
        return
    }
    $m = [regex]::Match($content, [regex]::Escape($begin) + '(?<body>.*?)' + [regex]::Escape($end), [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $section = $m.Groups['body'].Value
    $names = [regex]::Matches($section, '\|\s*\d+\s*\|\s*`([a-z0-9\-]+)`') | ForEach-Object { $_.Groups[1].Value }
    $listed = @{}
    foreach ($n in $names) { $listed[$n] = $true }
    $missing = @($Expected.Keys | Where-Object { -not $listed.ContainsKey($_) })
    $extra = @($listed.Keys | Where-Object { -not $Expected.ContainsKey($_) })
    if ($missing.Count -gt 0) { Add-Issue 'README' 'ERROR' 'ReadmeMissingEntries' "missing: $($missing -join ', ')" $true }
    if ($extra.Count -gt 0) { Add-Issue 'README' 'ERROR' 'ReadmeExtraEntries' "extra: $($extra -join ', ')" $true }
}

# ---------- checks 7 + 8: JUNCTION docs / README related links ----------
# All Chinese literals (file name, section title, line formats) come from
# sync-config.json; the doc template lives in templates\JUNCTION-template.md.
# This source stays ASCII-only.

$script:Domains = @('claude', 'dsh', 'codex', 'zcode')
$script:EndLabels = @{ claude = 'Claude Code'; dsh = 'DSH'; codex = 'Codex'; zcode = 'Zcode' }

# repo root of a skill (git-commit: repo root != skill dir)
function Get-RepoRootDir {
    param([object]$Cfg, [string]$Name)
    if ($Cfg.PSObject.Properties.Name -contains 'repoRoots') {
        $p = $Cfg.repoRoots.PSObject.Properties[$Name]
        if ($p) { return [string]$p.Value }
    }
    return (Join-Path $Cfg.repo $Name)
}

function Test-JunctionDocs {
    param([object]$Cfg, [hashtable]$Expected)
    if (-not $Cfg.junctionDoc.enabled) { return }
    $fileName = [string]$Cfg.junctionDoc.fileName
    # family sub-skills (dir nested under another skill's dir) share the family doc: skip
    $skillDirs = @($Expected.Values | ForEach-Object { Normalize-Path $_.Dir })
    foreach ($name in ($Expected.Keys | Sort-Object)) {
        $dir = $Expected[$name].Dir
        if ($skillDirs -contains (Normalize-Path (Split-Path -Parent $dir))) { continue }
        $docPath = Join-Path $dir $fileName
        if (-not (Test-Path -LiteralPath $docPath)) {
            Add-Issue 'docs' 'ERROR' 'JunctionDocMissing' "${name}:$fileName missing at $docPath" $true -LinkName $name -ExpectedDir $docPath
            continue
        }
        $text = Get-Content -LiteralPath $docPath -Raw -Encoding UTF8
        # stale skill name in doc (renamed skill left old token behind)
        $bad = @()
        foreach ($m in [regex]::Matches($text, '\\skills\\([a-z0-9\-]+)|idea-workspase-skills\\([a-z0-9\-]+)')) {
            $tok = $m.Groups[1].Value
            if (-not $tok) { $tok = $m.Groups[2].Value }
            if ($tok -and $tok -ne $name -and $name.EndsWith($tok)) { $bad += $tok }
        }
        $bad = @($bad | Select-Object -Unique)
        if ($bad.Count -gt 0) {
            Add-Issue 'docs' 'ERROR' 'JunctionDocStaleName' "${name}:doc uses stale name '$($bad -join ', ')' (actual: $name)" $true -LinkName $name -ExpectedDir $docPath
        }
        # polluted doc: a path token matching no known skill name (e.g. stacked
        # prefixes left by a bad rename) -> rebuild from template.
        # Context rules keep prose and backup paths from false-positiving:
        #   \skills\X / findstr X      -> X must be a known skill name
        #   idea-workspase-skills\X    -> X may be any repo subdirectory (repo dirs,
        #                                 backup dirs like _skills_backup_*) or a GitHub repo name
        $knownSet = @{}
        foreach ($k in @($Expected.Keys) + @($Cfg.relatedSkills.PSObject.Properties.Name)) { $knownSet[$k] = $true }
        if (-not $script:RepoDirNames) {
            $script:RepoDirNames = @{}
            foreach ($di in (Get-ChildItem -LiteralPath $Cfg.repo -Directory)) { $script:RepoDirNames[$di.Name] = $true }
            foreach ($k in $Cfg.githubRepos.PSObject.Properties) { $script:RepoDirNames[[string]$k.Value] = $true }
        }
        $polluted = @()
        foreach ($m in [regex]::Matches($text, '\\skills\\([a-z0-9\-]+)|idea-workspase-skills\\([a-z0-9\-]+)|findstr\s+([a-z0-9\-]+)')) {
            $tok = $m.Groups[1].Value; $ctx = 1
            if (-not $tok) { $tok = $m.Groups[2].Value; $ctx = 2 }
            if (-not $tok) { $tok = $m.Groups[3].Value; $ctx = 3 }
            if (-not $tok) { continue }
            if ($ctx -eq 2) {
                if (-not $script:RepoDirNames.ContainsKey($tok)) { $polluted += $tok }
            } elseif (-not $knownSet.ContainsKey($tok)) {
                $polluted += $tok
            }
        }
        $polluted = @($polluted | Select-Object -Unique)
        if ($polluted.Count -gt 0) {
            Add-Issue 'docs' 'ERROR' 'JunctionDocPolluted' "${name}: doc has unknown path tokens '$($polluted -join ', ')' - polluted by a bad rename, rebuild needed" $true -LinkName $name -ExpectedDir $docPath
        }
        $missingEnds = @()
        foreach ($a in $Cfg.agents) {
            if (-not $a.skillsEnabled) { continue }
            $needle = $a.home + '\skills\' + $name
            if ($text -notlike "*$needle*") { $missingEnds += $a.name }
        }
        if ($missingEnds.Count -gt 0) {
            Add-Issue 'docs' 'ERROR' 'JunctionDocMissingEnds' "${name}:doc missing ends: $($missingEnds -join ', ')" $true -LinkName $name -ExpectedDir $docPath
        }
    }
}

function Test-RelatedLinks {
    param([object]$Cfg, [hashtable]$Expected)
    $title = [string]$Cfg.readme.relatedSectionTitle
    if (-not $title) { return }
    $skillDirs = @($Expected.Values | ForEach-Object { Normalize-Path $_.Dir })
    foreach ($name in ($Expected.Keys | Sort-Object)) {
        # family sub-skills have no own README: skip
        $dir = $Expected[$name].Dir
        if ($skillDirs -contains (Normalize-Path (Split-Path -Parent $dir))) { continue }
        $root = Get-RepoRootDir $Cfg $name
        $rp = Join-Path $root 'README.md'
        if (-not (Test-Path -LiteralPath $rp)) {
            Add-Issue 'docs' 'WARN' 'ReadmeFileMissing' "${name}:README.md missing at $rp (write it per the 7-section template)" $false -LinkName $name
            continue
        }
        $text = Get-Content -LiteralPath $rp -Raw -Encoding UTF8
        $idx = $text.IndexOf($title)
        if ($idx -lt 0) {
            Add-Issue 'docs' 'WARN' 'RelatedSectionMissing' "${name}:README has no related-skills section" $false -LinkName $name
            continue
        }
        $next = $text.IndexOf("`n## ", $idx)
        if ($next -lt 0) { $next = $text.Length }
        $sec = $text.Substring($idx, $next - $idx)
        $missing = @()
        foreach ($other in $Cfg.relatedSkills.PSObject.Properties.Name) {
            if ($other -eq $name) { continue }
            $repoOf = [string]$Cfg.githubRepos.$other
            if (-not $repoOf) { continue }
            if ($sec -notlike "*huzhw/$repoOf)*") { $missing += $other }
        }
        if ($missing.Count -gt 0) {
            Add-Issue 'docs' 'ERROR' 'RelatedLinksMissing' "${name}:related links missing: $($missing -join ', ')" $true -LinkName $name
        }
    }
}

# insert missing per-end lines into one block (table rows / findstr lines / rd lines)
function Ensure-Block {
    param($Lines, [scriptblock]$IsLine, [hashtable]$NewLines)
    $idxs = @()
    for ($i = 0; $i -lt $Lines.Count; $i++) { if (& $IsLine $Lines[$i]) { $idxs += $i } }
    if ($idxs.Count -eq 0) { return $false }
    $present = @()
    foreach ($i in $idxs) {
        foreach ($d in $script:Domains) {
            if ($Lines[$i] -like "*.$d\skills*") { $present += $d }
        }
    }
    $need = @($script:Domains | Where-Object { $present -notcontains $_ })
    if ($need.Count -eq 0) { return $false }
    $insertAt = $idxs[$idxs.Count - 1]
    foreach ($d in $need) {
        $insertAt++
        $Lines.Insert($insertAt, $NewLines[$d])
    }
    return $true
}

function Fix-JunctionDoc {
    param([object]$Cfg, [string]$Name, [string]$DocPath, [switch]$Rebuild)
    $fileName = [string]$Cfg.junctionDoc.fileName
    $docPath = $DocPath
    if (-not $docPath) { $docPath = Join-Path (Join-Path $Cfg.repo $Name) $fileName }
    if ($Rebuild -or -not (Test-Path -LiteralPath $docPath)) {
        $tpl = Get-Content -LiteralPath ([string]$Cfg.junctionDoc.templatePath) -Raw -Encoding UTF8
        Write-NoBomUtf8 -Path $docPath -Text ($tpl.Replace('{NAME}', $Name))
        return
    }
    $text = Get-Content -LiteralPath $docPath -Raw -Encoding UTF8
    # 1. stale token -> actual name.
    #    tok is a SUFFIX of name (e.g. settings-curator vs deepseek-harness-settings-curator),
    #    so a naive String.Replace would re-match its own output and stack prefixes.
    #    Idempotent approach: collapse repeated-prefix damage, then anchor with a
    #    negative lookbehind so already-fixed text never matches again.
    $seen = @{}
    foreach ($m in [regex]::Matches($text, '\\skills\\([a-z0-9\-]+)|idea-workspase-skills\\([a-z0-9\-]+)')) {
        $tok = $m.Groups[1].Value
        if (-not $tok) { $tok = $m.Groups[2].Value }
        if ($tok -and $tok -ne $Name -and $Name.EndsWith($tok)) { $seen[$tok] = $true }
    }
    foreach ($tok in $seen.Keys) {
        $prefix = $Name.Substring(0, $Name.Length - $tok.Length)
        if ($prefix) {
            $text = [regex]::Replace($text, "(?:$prefix)+$tok", $Name)
            $text = [regex]::Replace($text, "(?<!$prefix)$tok", $Name)
        } else {
            $text = $text.Replace($tok, $Name)
        }
    }
    # 2. ensure four-end rows in table / check block / rollback block
    $agents = @($Cfg.agents | Where-Object { $_.skillsEnabled })
    $tableFmt = [string]$Cfg.junctionDoc.tableRowFormat
    $checkFmt = [string]$Cfg.junctionDoc.checkCmdFormat
    $rbFmt = [string]$Cfg.junctionDoc.rollbackCmdFormat

    $tableLines = @{}; $checkLines = @{}; $rbLines = @{}
    foreach ($d in $script:Domains) {
        # NOTE: do not name this $home - HOME is a read-only automatic variable
        $endHome = "C:\Users\Administrator\.$d"
        if ($agents | Where-Object { $_.name -eq $d }) {
            $tableLines[$d] = $tableFmt -f $script:EndLabels[$d], "$endHome\skills\$Name"
            $checkLines[$d] = $checkFmt -f $d, $Name
            $rbLines[$d] = $rbFmt -f $d, $Name
        }
    }
    $lines = [System.Collections.Generic.List[string]](($text -split "`r?`n"))
    $null = Ensure-Block $lines { param($s) $s.TrimStart().StartsWith('|') -and $s -like "*\skills\$Name*" } $tableLines
    $null = Ensure-Block $lines { param($s) $s -like "*findstr $Name*" } $checkLines
    $null = Ensure-Block $lines { param($s) $s.TrimStart().StartsWith('rd ') -and $s -like "*\skills\$Name*" } $rbLines
    Write-NoBomUtf8 -Path $docPath -Text ($lines -join "`r`n")
}

function Fix-RelatedLinks {
    param([object]$Cfg, [string]$Name)
    $root = Get-RepoRootDir $Cfg $Name
    $rp = Join-Path $root 'README.md'
    if (-not (Test-Path -LiteralPath $rp)) { return }
    $text = Get-Content -LiteralPath $rp -Raw -Encoding UTF8
    $title = [string]$Cfg.readme.relatedSectionTitle
    $idx = $text.IndexOf($title)
    if ($idx -lt 0) { return }
    $fmt = [string]$Cfg.readme.relatedLineFormat
    $next = $text.IndexOf("`n## ", $idx)
    if ($next -lt 0) { $next = $text.Length }
    $sec = $text.Substring($idx, $next - $idx)
    $newLines = @()
    foreach ($other in ($Cfg.relatedSkills.PSObject.Properties.Name | Sort-Object)) {
        if ($other -eq $Name) { continue }
        $repoOf = [string]$Cfg.githubRepos.$other
        if (-not $repoOf) { continue }
        if ($sec -notlike "*huzhw/$repoOf)*") {
            $newLines += ($fmt -f $other, $repoOf, ([string]$Cfg.relatedSkills.$other))
        }
    }
    if ($newLines.Count -eq 0) { return }
    $lines = [System.Collections.Generic.List[string]](($text -split "`r?`n"))
    $titleLine = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].StartsWith($title)) { $titleLine = $i; break }
    }
    if ($titleLine -lt 0) { return }
    $lastItem = $titleLine
    for ($i = $titleLine + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^## ') { break }
        if ($lines[$i] -match '^\s*-\s*\[') { $lastItem = $i }
    }
    $ins = $lastItem
    foreach ($nl in $newLines) {
        $ins++
        $lines.Insert($ins, $nl)
    }
    Write-NoBomUtf8 -Path $rp -Text ($lines -join "`r`n")
}

# ---------- fixes ----------

# Non-recursive delete of a junction - NEVER recurses into the target
function Remove-LinkSafe {
    param([string]$LinkPath)
    if (Test-Path -LiteralPath $LinkPath) {
        [IO.Directory]::Delete($LinkPath, $false)
        return $true
    }
    return $false
}

function New-Junction {
    param([string]$LinkPath, [string]$TargetDir)
    # PS 5.1 has no New-Item -ItemType Junction; mklink /J needs no admin rights
    if ($LinkPath -match '\s' -or $TargetDir -match '\s') {
        throw "path contains spaces, mklink needs extra quoting: $LinkPath / $TargetDir"
    }
    $parent = Split-Path -Parent $LinkPath
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    if (Test-Path -LiteralPath $LinkPath) {
        throw "link already exists: $LinkPath"
    }
    # redirect inside cmd (stdout+stderr to nul) - avoids sandbox stdout-capture issues;
    # success is verified below by Test-Path
    cmd /c "mklink /J $LinkPath $TargetDir >nul 2>&1"
    if (-not (Test-Path -LiteralPath $LinkPath)) {
        throw "mklink failed: $LinkPath -> $TargetDir"
    }
}

function Fix-ReadmeSection {
    param([object]$Cfg, [hashtable]$Expected)
    $p = $Cfg.readme.path
    $begin = $Cfg.readme.beginMark
    $end = $Cfg.readme.endMark
    $marked = $begin + (New-SkillsSection $Cfg $Expected) + $end

    if (-not (Test-Path -LiteralPath $p)) {
        # fallback: create a minimal skeleton
        $head = "# Skill Repo" + "`r`n`r`n" + "Single source of truth for self-built skills; 4 agent ends consume it via junctions." + "`r`n"
        Write-NoBomUtf8 -Path $p -Text ($head + $marked + "`r`n")
        return
    }
    $content = Get-Content -LiteralPath $p -Raw -Encoding UTF8
    $i1 = $content.IndexOf($begin)
    $i2 = $content.IndexOf($end)
    if ($i1 -ge 0 -and $i2 -gt $i1) {
        # marks intact: replace between them (marks included)
        $i2e = $i2 + $end.Length
        $new = $content.Substring(0, $i1) + $marked + $content.Substring($i2e)
    } else {
        # marks missing: append at file end (manual move later)
        $new = $content.TrimEnd() + "`r`n" + $marked + "`r`n"
    }
    Write-NoBomUtf8 -Path $p -Text $new
}

function Apply-Fixes {
    param([object]$Cfg, [hashtable]$Expected)

    foreach ($iss in $Issues.ToArray()) {
        if (-not $iss.Fixable) { continue }
        try {
            switch ($iss.Type) {
                'MissingLink' {
                    New-Junction -LinkPath $iss.LinkPath -TargetDir $iss.ExpectedDir
                    Write-Host "  [FIXED] $($iss.Agent): created skills\$($iss.LinkName) -> $($iss.ExpectedDir)"
                    $script:Fixed++
                }
                'WrongTarget' {
                    if ((Get-Item -LiteralPath $iss.LinkPath -Force).LinkType -eq 'Junction') {
                        Remove-LinkSafe $iss.LinkPath | Out-Null
                    }
                    New-Junction -LinkPath $iss.LinkPath -TargetDir $iss.ExpectedDir
                    Write-Host "  [FIXED] $($iss.Agent): rebuilt skills\$($iss.LinkName) -> $($iss.ExpectedDir)"
                    $script:Fixed++
                }
                'BrokenLink' {
                    if ((Get-Item -LiteralPath $iss.LinkPath -Force).LinkType -eq 'Junction') {
                        Remove-LinkSafe $iss.LinkPath | Out-Null
                    }
                    New-Junction -LinkPath $iss.LinkPath -TargetDir $iss.ExpectedDir
                    Write-Host "  [FIXED] $($iss.Agent): rebuilt broken link skills\$($iss.LinkName)"
                    $script:Fixed++
                }
                'DanglingLink' {
                    Remove-LinkSafe $iss.LinkPath | Out-Null
                    Write-Host "  [FIXED] $($iss.Agent): removed dangling link skills\$($iss.LinkName)"
                    $script:Fixed++
                }
                'ExtraRepoLink' {
                    Remove-LinkSafe $iss.LinkPath | Out-Null
                    Write-Host "  [FIXED] $($iss.Agent): removed extra repo link skills\$($iss.LinkName)"
                    $script:Fixed++
                }
                'RedlineLink' {
                    Remove-LinkSafe $iss.LinkPath | Out-Null
                    Write-Host "  [FIXED] $($iss.Agent): removed redline link skills\$($iss.LinkName)"
                    $script:Fixed++
                }
                'ReadmeMissing' {
                    Fix-ReadmeSection $Cfg $Expected
                    Write-Host "  [FIXED] README: created $((Split-Path -Parent $Cfg.readme.path)) with skill section"
                    $script:Fixed++
                }
                'ReadmeMarkMissing' {
                    Fix-ReadmeSection $Cfg $Expected
                    Write-Host "  [FIXED] README: added skill-list marks"
                    $script:Fixed++
                }
                'ReadmeMissingEntries' {
                    Fix-ReadmeSection $Cfg $Expected
                    Write-Host "  [FIXED] README: regenerated skill-list section"
                    $script:Fixed++
                }
                'ReadmeExtraEntries' {
                    Fix-ReadmeSection $Cfg $Expected
                    Write-Host "  [FIXED] README: regenerated skill-list section"
                    $script:Fixed++
                }
                'JunctionDocMissing' {
                    Fix-JunctionDoc $Cfg $iss.LinkName $iss.ExpectedDir
                    Write-Host "  [FIXED] $($iss.LinkName): created JUNCTION doc from template"
                    $script:Fixed++
                }
                'JunctionDocPolluted' {
                    # original text is recoverable from git HEAD, no backup needed
                    Fix-JunctionDoc $Cfg $iss.LinkName $iss.ExpectedDir -Rebuild
                    Write-Host "  [FIXED] $($iss.LinkName): rebuilt polluted JUNCTION doc from template"
                    $script:Fixed++
                }
                'JunctionDocStaleName' {
                    Fix-JunctionDoc $Cfg $iss.LinkName $iss.ExpectedDir
                    Write-Host "  [FIXED] $($iss.LinkName): replaced stale names in JUNCTION doc"
                    $script:Fixed++
                }
                'JunctionDocMissingEnds' {
                    Fix-JunctionDoc $Cfg $iss.LinkName $iss.ExpectedDir
                    Write-Host "  [FIXED] $($iss.LinkName): added missing ends in JUNCTION doc"
                    $script:Fixed++
                }
                'RelatedLinksMissing' {
                    Fix-RelatedLinks $Cfg $iss.LinkName
                    Write-Host "  [FIXED] $($iss.LinkName): filled missing related links in README"
                    $script:Fixed++
                }
                'SshJunctionMissing' {
                    New-Junction -LinkPath $iss.LinkPath -TargetDir $iss.ExpectedDir
                    Write-Host "  [FIXED] ssh-mcp: created junction $($iss.LinkPath) -> $($iss.ExpectedDir)"
                    $script:Fixed++
                }
                'SshJunctionWrongTarget' {
                    if ((Get-Item -LiteralPath $iss.LinkPath -Force).LinkType -eq 'Junction') {
                        Remove-LinkSafe $iss.LinkPath | Out-Null
                    }
                    New-Junction -LinkPath $iss.LinkPath -TargetDir $iss.ExpectedDir
                    Write-Host "  [FIXED] ssh-mcp: rebuilt junction $($iss.LinkPath) -> $($iss.ExpectedDir)"
                    $script:Fixed++
                }
                'SshJunctionBroken' {
                    if ((Get-Item -LiteralPath $iss.LinkPath -Force).LinkType -eq 'Junction') {
                        Remove-LinkSafe $iss.LinkPath | Out-Null
                    }
                    New-Junction -LinkPath $iss.LinkPath -TargetDir $iss.ExpectedDir
                    Write-Host "  [FIXED] ssh-mcp: rebuilt broken junction $($iss.LinkPath)"
                    $script:Fixed++
                }
                'SshMcpNotRegistered' {
                    Add-SshRegistration $Cfg $iss.LinkName
                    Write-Host "  [FIXED] ssh-mcp: registered server into end '$($iss.LinkName)'"
                    $script:Fixed++
                }
                'McpMissing' {
                    Add-McpRegistration $Cfg $iss.LinkName.Split('|')[0] $iss.LinkName.Split('|')[1]
                    Write-Host "  [FIXED] mcp-sync: registered '$($iss.LinkName)'"
                    $script:Fixed++
                }
                'McpDrift' {
                    Add-McpRegistration $Cfg $iss.LinkName.Split('|')[0] $iss.LinkName.Split('|')[1]
                    Write-Host "  [FIXED] mcp-sync: rewrote '$($iss.LinkName)' to match source form"
                    $script:Fixed++
                }
                'SshMcpLegacyRegistration' {
                    $sc = Get-SshCfg $Cfg
                    $endProp = $sc.registration.ends.PSObject.Properties[$iss.LinkName]
                    if ($endProp -and [string]$endProp.Value.type -eq 'claude-json') {
                        $helper = Join-Path $script:ScriptDir 'ssh-claude-register.js'
                        $out = & node $helper ([string]$endProp.Value.file) ([string]$endProp.Value.launcherPath) ([string]$endProp.Value.configPath) 2>&1
                        if ($LASTEXITCODE -ne 0 -or ($out | Out-String) -notlike '*CLAUDE_REGISTER_OK*') { throw "claude register helper failed: $out" }
                        Write-Host "  [FIXED] ssh-mcp: rewrote claude ssh registration to launcher form"
                        $script:Fixed++
                    } else {
                        Add-SshRegistration $Cfg $iss.LinkName
                        Write-Host "  [FIXED] ssh-mcp: migrated end '$($iss.LinkName)' to launcher form"
                        $script:Fixed++
                    }
                }
                'SshMcpStalePath' {
                    $sc = Get-SshCfg $Cfg
                    $endProp = $sc.registration.ends.PSObject.Properties[$iss.LinkName]
                    if ($endProp -and [string]$endProp.Value.type -eq 'claude-json') {
                        $helper = Join-Path $script:ScriptDir 'ssh-claude-register.js'
                        $out = & node $helper ([string]$endProp.Value.file) ([string]$endProp.Value.launcherPath) ([string]$endProp.Value.configPath) 2>&1
                        if ($LASTEXITCODE -ne 0 -or ($out | Out-String) -notlike '*CLAUDE_REGISTER_OK*') { throw "claude register helper failed: $out" }
                        Write-Host "  [FIXED] ssh-mcp: rewrote claude ssh registration to launcher form"
                        $script:Fixed++
                    }
                }
                default {
                    # not fixable by design
                }
            }
        } catch {
            Write-Host "  [FIX FAILED] $($iss.Agent)/$($iss.Type): $($_.Exception.Message)"
        }
    }
}

# ---------- main ----------

$cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$repo = $cfg.repo
if (-not (Test-Path -LiteralPath $repo)) {
    Write-Host "repo not found: $repo"; exit 1
}
if (-not (Test-Path -LiteralPath $script:LogDir)) {
    New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
}

$found = Find-ExpectedSkills -Repo $repo -ExcludeDirs @($cfg.excludeDirs)
$expected = $found.Expected

function Invoke-AllChecks {
    param([object]$Cfg, [hashtable]$Expected, [object]$Found)
    $script:Issues = [System.Collections.Generic.List[object]]::new()
    foreach ($bad in $Found.FrontmatterIssues) { Add-Issue 'repo' 'ERROR' 'Frontmatter' $bad $false }
    foreach ($a in $Cfg.agents) {
        if ($a.skillsEnabled) {
            Test-AgentLinks -Agent $a -Expected $Expected -Repo $Cfg.repo -RedlineDirs @($Cfg.redlineDirs)
        }
    }
    Test-RulesHardlink $Cfg
    Test-SshMcpJunction $Cfg
    Test-SshMcpRegistration $Cfg
    Test-McpSync $Cfg
    Test-Readme $Cfg $Expected
    Test-JunctionDocs $Cfg $Expected
    Test-RelatedLinks $Cfg $Expected
}

Invoke-AllChecks -Cfg $cfg -Expected $expected -Found $found

# re-check after fixes
if ($Fix) {
    Apply-Fixes -Cfg $cfg -Expected $expected
    Invoke-AllChecks -Cfg $cfg -Expected $expected -Found $found
}

# ---------- report + log ----------

$agentsChecked = (@($cfg.agents | Where-Object { $_.skillsEnabled }).name) -join ','
$errCount = @($Issues | Where-Object { $_.Level -eq 'ERROR' }).Count
$warnCount = @($Issues | Where-Object { $_.Level -eq 'WARN' }).Count
$fixableCount = @($Issues | Where-Object { $_.Fixable }).Count
$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$pass = ($errCount -eq 0)

if (-not $Quiet) {
    Write-Host ""
    Write-Host "=== agent-config-sync-check  $stamp ==="
    Write-Host ("Expected skills: {0} | Agents: {1} | Fix mode: {2}" -f $expected.Count, $agentsChecked, ($(if ($Fix) { 'YES' } else { 'NO' })))
    Write-Host ""
    if ($Issues.Count -eq 0) {
        Write-Host "ALL GREEN: links / dangling / hardlink group / frontmatter / README / redline / ssh-mcp all pass" -ForegroundColor Green
    } else {
        foreach ($iss in ($Issues | Sort-Object Agent, Type)) {
            $color = if ($iss.Level -eq 'ERROR') { 'Red' } else { 'Yellow' }
            $fx = if ($iss.Fixable) { ' [auto-fixable]' } else { '' }
            Write-Host ("[{0}] [{1}] {2}: {3}{4}" -f $iss.Level, $iss.Agent, $iss.Type, $iss.Detail, $fx) -ForegroundColor $color
        }
    }
    if ($Fix -and $script:Fixed -gt 0) { Write-Host ("Auto-fixed: {0}" -f $script:Fixed) -ForegroundColor Cyan }
    Write-Host ""
    Write-Host ("--- Result: errors {0} / warnings {1} (auto-fixable {2}) ---" -f $errCount, $warnCount, $fixableCount)
    Write-Host ("Status: {0}" -f ($(if ($pass) { '[PASS]' } else { '[FAIL]' })))
}

# log (append, no-BOM UTF-8)
$errLines = @()
foreach ($iss in $Issues) {
    $errLines += ("    [{0}] [{1}] {2}: {3}" -f $iss.Level, $iss.Agent, $iss.Type, $iss.Detail)
}
$fixMode = 'NO'
if ($Fix) { $fixMode = 'YES' }
$verdict = 'FAIL'
if ($pass) { $verdict = 'PASS' }
$summary = "[{0}] agent-config-sync-check  skills={1} agents={2} fix={3} errors={4} warnings={5} fixed={6} result={7}" -f $stamp, $expected.Count, $agentsChecked, $fixMode, $errCount, $warnCount, $script:Fixed, $verdict
$logText = @("") + $summary
if ($errLines.Count -gt 0) { $logText = $logText + $errLines }
Append-NoBomUtf8 -Path (Join-Path $script:LogDir 'sync-check.log') -Text (($logText -join "`r`n") + "`r`n")

exit $(if ($pass) { 0 } else { 1 })
