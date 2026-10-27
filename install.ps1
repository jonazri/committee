#Requires -Version 5.1
<#
.SYNOPSIS
  Install committee + committee-loop into a Claude Code config dir via symlinks (Windows port of install.sh).

.DESCRIPTION
  Makes /committee and /committee-loop available in every Claude Code session.

  Run from the repo root after cloning:
    git clone https://github.com/jonazri/committee.git; cd committee; .\install.ps1 [-ConfigDir <dir>[,<dir>...]]

  Claude Code reads user skills and named workflows from the active config dir
  ($env:CLAUDE_CONFIG_DIR, else ~/.claude), so install into every config dir you run sessions under.
  Targets: each -ConfigDir (must exist), else $env:CLAUDE_CONFIG_DIR, else ~/.claude.
  Re-running is safe - existing links are replaced in place.

  Symlinks on Windows require an elevated (Administrator) PowerShell, or PowerShell 7+
  (pwsh) with Developer Mode on (Settings > System > For developers); Windows PowerShell 5.1
  needs elevation even in Developer Mode. The prompts/ directory falls back to a
  directory junction (no privilege needed); the SKILL.md / workflow file links cannot
  fall back, because committee-loop resolves its helper scripts via `readlink -f` on the
  SKILL.md symlink - a copy would silently break that lookup.

  Also adds an allow rule for the committee-loop spawn command to permissions.allow in
  each target's settings.json (skip with -NoPermissionRule). spawn.sh launches a detached
  `claude --dangerously-skip-permissions` session (inside WSL on Windows), which Claude
  Code's auto-mode classifier blocks unless that exact command is allow-listed.

  Uninstall (per config dir <dir>; delete the prompts link first, without recursing, so the
  clone's prompts/ is never touched):
    (Get-Item <dir>\skills\committee\prompts -Force).Delete()
    Remove-Item -Recurse -Force <dir>\skills\committee, <dir>\skills\committee-loop
    Remove-Item -Force <dir>\workflows\committee-review.js
    (and remove the committee-loop spawn.sh rule from permissions.allow in <dir>\settings.json)

.PARAMETER ConfigDir
  Claude Code config dirs to install into (each must exist). Default: $env:CLAUDE_CONFIG_DIR, else ~/.claude.

.PARAMETER NoPermissionRule
  Don't add the committee-loop spawn allow rule to the targets' settings.json.
#>
[CmdletBinding()]
param(
  [string[]]$ConfigDir,
  [switch]$NoPermissionRule
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path -LiteralPath $PSScriptRoot).ProviderPath

if ($ConfigDir) {
  foreach ($d in $ConfigDir) {
    if (-not (Test-Path -LiteralPath $d -PathType Container)) {
      [Console]::Error.WriteLine("install.ps1: config dir not found: $d")
      exit 1
    }
  }
  $ConfigDirs = @($ConfigDir | ForEach-Object { (Resolve-Path -LiteralPath $_).ProviderPath })
} elseif ($env:CLAUDE_CONFIG_DIR) {
  $ConfigDirs = @($env:CLAUDE_CONFIG_DIR)
} else {
  $ConfigDirs = @(Join-Path $HOME '.claude')
}

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

# The new link is built beside $Target and swapped in only after it exists, so a failed
# (e.g. non-elevated) re-run leaves a working install untouched.
function New-SafeSymlink([string]$Source, [string]$Target) {
  $existing = Get-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue
  if ($existing -and $existing.LinkType -and @($existing.Target).Count -gt 0 -and
      (Get-NormalizedPath @($existing.Target)[0]) -ieq (Get-NormalizedPath $Source)) {
    return
  }
  $staging = "$Target.committee-new"
  Remove-InstallTarget $staging
  try {
    New-Item -ItemType SymbolicLink -Path $staging -Target $Source -ErrorAction Stop | Out-Null
  } catch {
    $symlinkError = $_
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
      [Console]::Error.WriteLine("install.ps1: could not create symlink $Target -> $Source")
      [Console]::Error.WriteLine("  $($symlinkError.Exception.Message)")
      [Console]::Error.WriteLine("  Re-run from an elevated PowerShell, or with PowerShell 7+ (pwsh) and Developer Mode on")
      [Console]::Error.WriteLine("  (Windows PowerShell 5.1 needs elevation even in Developer Mode). A file copy is NOT used as a fallback: committee-loop resolves")
      [Console]::Error.WriteLine("  its helper scripts through the SKILL.md symlink.")
      exit 1
    }
    # Junctions need no special privilege and are followed transparently for directories.
    New-Item -ItemType Junction -Path $staging -Target $Source -ErrorAction Stop | Out-Null
    Write-Warning "Created a directory junction (not a symlink) for $Target"
  }
  Remove-InstallTarget $Target
  Rename-Item -LiteralPath $staging -NewName (Split-Path -Leaf $Target)
}

# Allow rule for the committee-loop spawn. SKILL.md invokes `bash <real skill dir>/spawn.sh ...`
# from Git Bash with the literal `readlink -f` path - the MSYS form /c/Users/... - so the rule
# uses that form. A rule for another clone is replaced once that clone's spawn.sh no longer
# exists. node (when present) rewrites settings.json with the same 2-space formatting Claude
# Code uses; Windows PowerShell 5.1's ConvertTo-Json is the fallback. The node script avoids
# double quotes: PowerShell 5.1 does not escape them when passing arguments to native programs.
$rule = $null
$staleRule = '^Bash\(bash (.*/\.claude/skills/committee-loop/spawn\.sh):\*\)$'
if (-not $NoPermissionRule) {
  if ($RepoRoot -match '^([A-Za-z]):\\(.*)$') {
    $msysRoot = '/' + $Matches[1].ToLower() + '/' + ($Matches[2] -replace '\\', '/')
    $rule = "Bash(bash $msysRoot/.claude/skills/committee-loop/spawn.sh:*)"
    if ($msysRoot -match '[^A-Za-z0-9._/+@:-]') {
      Write-Warning "$RepoRoot contains characters bash cannot take unquoted; the spawn invocation will not match the allow rule. Use a clone path of letters, digits and . _ - + @ : / only."
    }
  } else {
    Write-Warning "Repo path $RepoRoot is not a drive-letter path; add `"Bash(bash <repo>/.claude/skills/committee-loop/spawn.sh:*)`" (Git Bash path form) to permissions.allow in each config dir's settings.json yourself."
  }
}

function Add-SpawnRule([string]$SettingsPath) {
  try {
    if (Get-Command node -ErrorAction SilentlyContinue) {
      $env:COMMITTEE_SETTINGS = $SettingsPath
      $env:COMMITTEE_SPAWN_RULE = $rule
      try {
        node -e @'
const fs = require('fs');
const p = process.env.COMMITTEE_SETTINGS, rule = process.env.COMMITTEE_SPAWN_RULE;
const text = (fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : '').replace(/^\uFEFF/, '');
const s = text.trim() ? JSON.parse(text) : {};
const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
if (!isObj(s)) throw new Error(p + ' is not a JSON object');
if (s.permissions == null) s.permissions = {};
if (!isObj(s.permissions)) throw new Error('permissions in ' + p + ' is not a JSON object');
const allow = Array.isArray(s.permissions.allow) ? s.permissions.allow : [];
const local = (f) => process.platform === 'win32' ? f.replace(/^\/([A-Za-z])\//, '$1:/') : f;
const stale = (r) => {
  const m = /^Bash\(bash (.*\/\.claude\/skills\/committee-loop\/spawn\.sh):\*\)$/.exec(r);
  return m !== null && r !== rule && !fs.existsSync(local(m[1]));
};
const next = allow.filter(r => !stale(r));
if (!next.includes(rule)) next.push(rule);
if (JSON.stringify(next) === JSON.stringify(allow)) process.exit(0);
s.permissions.allow = next;
fs.writeFileSync(p, JSON.stringify(s, null, 2) + '\n');
console.log('Added permission rule to ' + p + ': ' + rule);
'@
        if ($LASTEXITCODE -ne 0) { throw "node exited with $LASTEXITCODE" }
      } finally {
        Remove-Item Env:COMMITTEE_SETTINGS, Env:COMMITTEE_SPAWN_RULE -ErrorAction SilentlyContinue
      }
    } else {
      $settings = $null
      if (Test-Path -LiteralPath $SettingsPath -PathType Leaf) {
        $text = [System.IO.File]::ReadAllText($SettingsPath)
        if ($text.Trim()) { $settings = $text | ConvertFrom-Json }
      }
      if ($null -eq $settings) { $settings = [pscustomobject]@{} }
      if ($settings -isnot [pscustomobject]) { throw "$SettingsPath is not a JSON object" }
      # Properties['x'] (not .Properties.Name) - StrictMode throws on .Name of an empty collection.
      $permProp = $settings.PSObject.Properties['permissions']
      if ($null -eq $permProp -or $null -eq $permProp.Value) {
        $settings | Add-Member -NotePropertyName permissions -NotePropertyValue ([pscustomobject]@{}) -Force
      }
      $perms = $settings.permissions
      if ($perms -isnot [pscustomobject]) { throw "permissions in $SettingsPath is not a JSON object" }
      $allow = @()
      $allowProp = $perms.PSObject.Properties['allow']
      if ($null -ne $allowProp -and $null -ne $allowProp.Value) { $allow = @($allowProp.Value) }
      $next = @($allow | Where-Object {
          $m = [regex]::Match([string]$_, $staleRule)
          -not ($m.Success -and $_ -cne $rule -and
                -not (Test-Path -LiteralPath ($m.Groups[1].Value -replace '^/([A-Za-z])/', '$1:/')))
        })
      if ($next -cnotcontains $rule) { $next += $rule }
      if (($allow -join "`n") -cne ($next -join "`n")) {
        $perms | Add-Member -NotePropertyName allow -NotePropertyValue ([object[]]$next) -Force
        $json = $settings | ConvertTo-Json -Depth 64
        [System.IO.File]::WriteAllText($SettingsPath, $json + "`n", (New-Object System.Text.UTF8Encoding $false))
        Write-Host "Added permission rule to ${SettingsPath}: $rule"
      }
    }
  } catch {
    Write-Warning "Could not update $SettingsPath ($($_.Exception.Message)). Add this to permissions.allow yourself: `"$rule`""
  }
}

foreach ($ClaudeDir in $ConfigDirs) {
  $SkillsDir = Join-Path $ClaudeDir 'skills'
  foreach ($d in @((Join-Path $SkillsDir 'committee'), (Join-Path $SkillsDir 'committee-loop'), (Join-Path $ClaudeDir 'workflows'))) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
  }

  # /committee - skill discovery needs a real dir; SKILL.md can be a symlink
  # (SKILL.md's lookup uses readlink -f to find the real skill dir containing
  # prepare.sh). The reviewer/verifier templates + committee-review workflow load from
  # prompts/ at <config dir>/skills/committee/prompts/ for user-global installs.
  New-SafeSymlink (Join-Path $RepoRoot '.claude\skills\committee\SKILL.md') (Join-Path $SkillsDir 'committee\SKILL.md')
  New-SafeSymlink (Join-Path $RepoRoot 'prompts') (Join-Path $SkillsDir 'committee\prompts')

  # Named user-scope workflow so the skill can invoke Workflow({name:"committee-review"}).
  # Rides the same source-of-truth as prompts/ - edits to the workflow are live.
  New-SafeSymlink (Join-Path $RepoRoot 'prompts\committee-review.js') (Join-Path $ClaudeDir 'workflows\committee-review.js')

  # /committee-loop - same pattern; spawn.sh is resolved via readlink -f on SKILL.md
  New-SafeSymlink (Join-Path $RepoRoot '.claude\skills\committee-loop\SKILL.md') (Join-Path $SkillsDir 'committee-loop\SKILL.md')

  if ($rule) { Add-SpawnRule (Join-Path $ClaudeDir 'settings.json') }

  Write-Host "Installed committee + committee-loop to $ClaudeDir (skills\, workflows\)"
}
Write-Host "  source: $RepoRoot"
Write-Host "Start a new Claude Code session and /committee + /committee-loop will be available."
