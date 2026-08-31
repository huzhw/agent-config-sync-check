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
        Write-Host "ALL GREEN: links / dangling / hardlink group / frontmatter / README / redline all pass" -ForegroundColor Green
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
