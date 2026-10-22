#Requires -Version 5.1
<#
.SYNOPSIS
  Install committee + committee-loop into ~/.claude/skills/ via symlinks (Windows port of install.sh).

.DESCRIPTION
  Makes /committee and /committee-loop available in every Claude Code session.

  Run from the repo root after cloning:
    git clone https://github.com/jonazri/committee.git; cd committee; .\install.ps1

  Re-running is safe - existing links are replaced in place.

  Symlinks on Windows require either Developer Mode (Settings > System > For developers)
  or an elevated (Administrator) PowerShell. The prompts/ directory falls back to a
  directory junction (no privilege needed); the SKILL.md / workflow file links cannot
  fall back, because committee-loop resolves its helper scripts via `readlink -f` on the
  SKILL.md symlink - a copy would silently break that lookup.

  Also adds an allow rule for the committee-loop spawn command to permissions.allow in
  ~/.claude/settings.json (skip with -NoPermissionRule). spawn.sh launches a detached
  `claude --dangerously-skip-permissions` session (inside WSL on Windows), which Claude
  Code's auto-mode classifier blocks unless that exact command is allow-listed.

  Uninstall:
    Remove-Item -Recurse -Force ~/.claude/skills/committee, ~/.claude/skills/committee-loop
    Remove-Item -Force ~/.claude/workflows/committee-review.js
    (and remove the committee-loop spawn.sh rule from permissions.allow in ~/.claude/settings.json)

.PARAMETER NoPermissionRule
  Don't add the committee-loop spawn allow rule to ~/.claude/settings.json.
#>
[CmdletBinding()]
param(
  [switch]$NoPermissionRule
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path -LiteralPath $PSScriptRoot).ProviderPath
$ClaudeDir = Join-Path $HOME '.claude'
$SkillsDir = Join-Path $ClaudeDir 'skills'

function Get-NormalizedPath([string]$Path) {
  [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

# Refuse to run from a LINKED git worktree. install.ps1 repoints the global ~/.claude symlinks
# at $RepoRoot; if a committee/committee-loop reviewer ever runs it from an ephemeral worktree
# (e.g. while reviewing a plan that says "Run: .\install.ps1"), those symlinks would point into a
# directory that later gets torn down - silently breaking the global /committee + /committee-loop
# install. In the primary checkout the git-dir equals the common-dir; in a linked worktree they
# differ. Non-git installs skip this guard (both values come back empty).
if (Get-Command git -ErrorAction SilentlyContinue) {
  $gd = $null; $gcd = $null
  try {
    $gd = git -C $RepoRoot rev-parse --absolute-git-dir 2>$null
    $gcd = git -C $RepoRoot rev-parse --git-common-dir 2>$null
  } catch { }
  if ($gd -and $gcd) {
    if (-not [System.IO.Path]::IsPathRooted($gcd)) { $gcd = Join-Path $RepoRoot $gcd }
    if ((Get-NormalizedPath $gd) -ine (Get-NormalizedPath $gcd)) {
      [Console]::Error.WriteLine("install.ps1: refusing to run from a linked git worktree:")
      [Console]::Error.WriteLine("  $RepoRoot")
      [Console]::Error.WriteLine("  Installing from a worktree repoints your global ~/.claude symlinks at a directory")
      [Console]::Error.WriteLine("  that may later be removed. Run install.ps1 from your primary committee clone instead.")
      exit 1
    }
  }
}

foreach ($f in @(
    (Join-Path $RepoRoot '.claude\skills\committee\SKILL.md'),
    (Join-Path $RepoRoot '.claude\skills\committee-loop\SKILL.md'),
    (Join-Path $RepoRoot 'prompts\committee-review.js'))) {
  if (-not (Test-Path -LiteralPath $f -PathType Leaf)) {
    [Console]::Error.WriteLine("install.ps1 must run from the committee repo root (missing $f)")
    exit 1
  }
}

foreach ($d in @((Join-Path $SkillsDir 'committee'), (Join-Path $SkillsDir 'committee-loop'), (Join-Path $ClaudeDir 'workflows'))) {
  New-Item -ItemType Directory -Force -Path $d | Out-Null
}

# Remove whatever currently sits at $Target. Links (symlinks/junctions) are removed WITHOUT
# recursing - Windows PowerShell 5.1's Remove-Item -Recurse on a directory link can delete the
# link target's contents (i.e. this repo's prompts/). A pre-existing real directory (migration
# case from the old copy-based install) is deleted recursively.
function Remove-InstallTarget([string]$Target) {
  $item = Get-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue
  if (-not $item) { return }
  $isLink = [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
  if ($item.PSIsContainer) {
    if ($isLink) { [System.IO.Directory]::Delete($item.FullName, $false) }
    else { Remove-Item -LiteralPath $item.FullName -Recurse -Force }
  } else {
    [System.IO.File]::Delete($item.FullName)
  }
}

function New-SafeSymlink([string]$Source, [string]$Target) {
  Remove-InstallTarget $Target
  try {
    New-Item -ItemType SymbolicLink -Path $Target -Target $Source -ErrorAction Stop | Out-Null
    return
  } catch {
    $symlinkError = $_
  }
  if (Test-Path -LiteralPath $Source -PathType Container) {
    # Junctions need no special privilege and are followed transparently for directories.
    New-Item -ItemType Junction -Path $Target -Target $Source -ErrorAction Stop | Out-Null
    Write-Warning "Created a directory junction (not a symlink) for $Target"
    return
  }
  [Console]::Error.WriteLine("install.ps1: could not create symlink $Target -> $Source")
  [Console]::Error.WriteLine("  $($symlinkError.Exception.Message)")
  [Console]::Error.WriteLine("  Enable Developer Mode (Settings > System > For developers) or re-run from an")
  [Console]::Error.WriteLine("  elevated PowerShell. A file copy is NOT used as a fallback: committee-loop resolves")
  [Console]::Error.WriteLine("  its helper scripts through the SKILL.md symlink.")
  exit 1
}

# /committee - skill discovery needs a real dir; SKILL.md can be a symlink
# (SKILL.md's lookup uses readlink -f to find the real skill dir containing
# prepare.sh). The reviewer/verifier templates + committee-review workflow load from
# prompts/ at ~/.claude/skills/committee/prompts/ for user-global installs.
New-SafeSymlink (Join-Path $RepoRoot '.claude\skills\committee\SKILL.md') (Join-Path $SkillsDir 'committee\SKILL.md')
New-SafeSymlink (Join-Path $RepoRoot 'prompts') (Join-Path $SkillsDir 'committee\prompts')

# Named user-scope workflow so the skill can invoke Workflow({name:"committee-review"}).
# Rides the same source-of-truth as prompts/ - edits to the workflow are live.
New-SafeSymlink (Join-Path $RepoRoot 'prompts\committee-review.js') (Join-Path $ClaudeDir 'workflows\committee-review.js')

# /committee-loop - same pattern; spawn.sh is resolved via readlink -f on SKILL.md
New-SafeSymlink (Join-Path $RepoRoot '.claude\skills\committee-loop\SKILL.md') (Join-Path $SkillsDir 'committee-loop\SKILL.md')

# Allow rule for the committee-loop spawn. SKILL.md invokes `bash <real skill dir>/spawn.sh ...`
# from Git Bash with the literal `readlink -f` path - the MSYS form /c/Users/... - so the rule
# uses that form. Stale rules for an older clone location are replaced. node (when present)
# rewrites settings.json with the same 2-space formatting Claude Code uses; Windows
# PowerShell 5.1's ConvertTo-Json is the fallback.
if (-not $NoPermissionRule) {
  if ($RepoRoot -match '^([A-Za-z]):\\(.*)$') {
    $msysRoot = '/' + $Matches[1].ToLower() + '/' + ($Matches[2] -replace '\\', '/')
    $rule = "Bash(bash $msysRoot/.claude/skills/committee-loop/spawn.sh:*)"
    $settingsPath = Join-Path $ClaudeDir 'settings.json'
    $stale = '^Bash\(bash .*/\.claude/skills/committee-loop/spawn\.sh:\*\)$'
    try {
      if (Get-Command node -ErrorAction SilentlyContinue) {
        $env:COMMITTEE_SETTINGS = $settingsPath
        $env:COMMITTEE_SPAWN_RULE = $rule
        $env:COMMITTEE_STALE_RULE = $stale
        try {
          node -e @'
const fs = require('fs');
const p = process.env.COMMITTEE_SETTINGS, rule = process.env.COMMITTEE_SPAWN_RULE;
const stale = new RegExp(process.env.COMMITTEE_STALE_RULE);
const raw = fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : '';
const text = raw.charCodeAt(0) === 0xFEFF ? raw.slice(1) : raw;
const s = text.trim() ? JSON.parse(text) : {};
s.permissions = s.permissions || {};
const allow = Array.isArray(s.permissions.allow) ? s.permissions.allow : [];
const next = allow.filter(r => r === rule || !stale.test(r));
if (!next.includes(rule)) next.push(rule);
if (JSON.stringify(next) === JSON.stringify(allow)) process.exit(0);
s.permissions.allow = next;
fs.writeFileSync(p, JSON.stringify(s, null, 2) + '\n');
console.log('Added permission rule to ' + p + ': ' + rule);
'@
          if ($LASTEXITCODE -ne 0) { throw "node exited with $LASTEXITCODE" }
        } finally {
          Remove-Item Env:COMMITTEE_SETTINGS, Env:COMMITTEE_SPAWN_RULE, Env:COMMITTEE_STALE_RULE -ErrorAction SilentlyContinue
        }
      } else {
        $settings = $null
        if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
          $text = [System.IO.File]::ReadAllText($settingsPath)
          if ($text.Trim()) { $settings = $text | ConvertFrom-Json }
        }
        if ($null -eq $settings) { $settings = [pscustomobject]@{} }
        # Properties['x'] (not .Properties.Name) - StrictMode throws on .Name of an empty collection.
        $permProp = $settings.PSObject.Properties['permissions']
        if ($null -eq $permProp -or $null -eq $permProp.Value) {
          $settings | Add-Member -NotePropertyName permissions -NotePropertyValue ([pscustomobject]@{}) -Force
        }
        $perms = $settings.permissions
        $allow = @()
        $allowProp = $perms.PSObject.Properties['allow']
        if ($null -ne $allowProp -and $null -ne $allowProp.Value) { $allow = @($allowProp.Value) }
        $next = @($allow | Where-Object { $_ -ceq $rule -or $_ -notmatch $stale })
        if ($next -cnotcontains $rule) { $next += $rule }
        if (($allow -join "`n") -cne ($next -join "`n")) {
          $perms | Add-Member -NotePropertyName allow -NotePropertyValue ([object[]]$next) -Force
          $json = $settings | ConvertTo-Json -Depth 64
          [System.IO.File]::WriteAllText($settingsPath, $json + "`n", (New-Object System.Text.UTF8Encoding $false))
          Write-Host "Added permission rule to ${settingsPath}: $rule"
        }
      }
    } catch {
      Write-Warning "Could not update $settingsPath ($($_.Exception.Message)). Add this to permissions.allow yourself: `"$rule`""
    }
  } else {
    Write-Warning "Repo path $RepoRoot is not a drive-letter path; add `"Bash(bash <repo>/.claude/skills/committee-loop/spawn.sh:*)`" (Git Bash path form) to permissions.allow in ~/.claude/settings.json yourself."
  }
}

Write-Host "Installed committee + committee-loop to $SkillsDir"
Write-Host "  source: $RepoRoot"
Write-Host "Start a new Claude Code session and /committee + /committee-loop will be available."
