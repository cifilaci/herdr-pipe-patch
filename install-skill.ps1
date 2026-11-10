<#
.SYNOPSIS
  Installs the Herdr pipe-patch skill for codex and Claude Code, and refreshes
  the Herdr guide they read.

.DESCRIPTION
  Two different things go into the agent's skill folder:

  - `herdr-pipe-patch` - the skill in this repository. It tells an agent how to
    grant other accounts access to the herdr-core pipes, how to set the codex side
    up, and when to stop and ask the person. It is copied as it is.

  - `herdr` - the guide an agent reads to drive Herdr at all. It is built from the
    manuals the *installed* binaries print (`hc --skill` and `herdr-app --skill`),
    with the head this repository carries in front of them. The head is a local
    addition: the frontmatter, the `HC_TERMINAL_ID` gate and the note that there
    is no `HERDR_ENV` in this Herdr. The manuals themselves are the upstream text
    and are never copied into this repository - they are read from the machine.

  Codex reads `~/.codex/skills/<name>/SKILL.md`, Claude Code reads
  `~/.claude/skills/<name>/SKILL.md`.

.EXAMPLE
  .\install-skill.ps1
  .\install-skill.ps1 -Target Codex
  .\install-skill.ps1 -Only HerdrGuide
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    # Where to install: both (default), Codex, or ClaudeCode.
    [ValidateSet('Both', 'Codex', 'ClaudeCode')]
    [string] $Target = 'Both',

    # Only install the pipe-patch skill, or only the Herdr guide.
    [ValidateSet('All', 'PipePatch', 'HerdrGuide')]
    [string] $Only = 'All',

    # Print what would happen and change nothing.
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillSource = Join-Path $root 'skills\herdr-pipe-patch'
$wrapperSource = Join-Path $root 'assets\herdr-skill-wrapper.md'

function Write-Step { param([string] $Message) Write-Host "==> $Message" }
function Write-Note { param([string] $Message) Write-Host "    $Message" }
function Write-Fail { param([string] $Message) Write-Host "    x $Message"; exit 1 }

# The output of a program has to travel through a pipeline: a program that writes
# to stdout from a GUI subsystem (the herdr app) panics when PowerShell captures
# its output into a variable instead.
function Get-ProgramOutput {
    param([string] $File, [string[]] $Arguments)
    $previous = $ErrorActionPreference
    $previousEncoding = [Console]::OutputEncoding
    $ErrorActionPreference = 'Continue'
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    try {
        $text = (& $File @Arguments 2>&1 | Out-String).Trim()
    } finally {
        $ErrorActionPreference = $previous
        [Console]::OutputEncoding = $previousEncoding
    }
    return $text
}

function Get-SkillFolders {
    $folders = @()
    if ($Target -in @('Both', 'Codex')) { $folders += (Join-Path $env:USERPROFILE '.codex\skills') }
    if ($Target -in @('Both', 'ClaudeCode')) { $folders += (Join-Path $env:USERPROFILE '.claude\skills') }
    return $folders
}

function Install-PipePatchSkill {
    param([string[]] $Folders)
    if (-not (Test-Path -LiteralPath $skillSource)) { Write-Fail "no skill at $skillSource" }
    foreach ($folder in $Folders) {
        $target = Join-Path $folder 'herdr-pipe-patch'
        if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Force -Path $target | Out-Null }
        Copy-Item -LiteralPath (Join-Path $skillSource 'SKILL.md') -Destination (Join-Path $target 'SKILL.md') -Force
        Write-Note "installed the pipe-patch skill into $target"
    }
}

function Install-HerdrGuide {
    param([string[]] $Folders)

    $hc = Join-Path $env:LOCALAPPDATA 'Programs\herdr-core\herdr-core.exe'
    if (-not (Test-Path -LiteralPath $hc)) { $hc = $null }
    $app = Join-Path $env:LOCALAPPDATA 'Programs\herdr-app\herdr-app.exe'
    if (-not (Test-Path -LiteralPath $app)) { $app = $null }
    if (-not $hc -or -not $app) {
        Write-Fail 'herdr-core and herdr-app have to be installed for the guide: it is built from the manuals those binaries print.'
    }

    $hcManual = Get-ProgramOutput -File $hc -Arguments @('--skill')
    $appManual = Get-ProgramOutput -File $app -Arguments @('--skill')
    if (-not $hcManual -or -not $appManual) { Write-Fail 'a manual could not be read.' }
    if (-not (Test-Path -LiteralPath $wrapperSource)) { Write-Fail "no guide head at $wrapperSource" }

    $wrapper = [IO.File]::ReadAllText($wrapperSource)
    $guide = $wrapper + ($hcManual -replace "`r`n", "`n").Trim() + "`n---`n`n" + ($appManual -replace "`r`n", "`n").Trim() + "`n"

    foreach ($folder in $Folders) {
        $target = Join-Path $folder 'herdr'
        if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Force -Path $target | Out-Null }
        $file = Join-Path $target 'SKILL.md'
        if (Test-Path -LiteralPath $file) {
            $backup = "$file.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
            Copy-Item -LiteralPath $file -Destination $backup -Force
            Write-Note "kept the old guide as $backup"
        }
        [IO.File]::WriteAllText($file, $guide, [System.Text.UTF8Encoding]::new($false))
        Write-Note "wrote the Herdr guide into $file"
    }
}

$folders = Get-SkillFolders
Write-Step "installing into: $($folders -join ', ')"

if ($Only -in @('All', 'PipePatch')) {
    if ($DryRun) { Write-Note 'dry run: the pipe-patch skill was not written' }
    else { Install-PipePatchSkill -Folders $folders }
}
if ($Only -in @('All', 'HerdrGuide')) {
    if ($DryRun) { Write-Note 'dry run: the Herdr guide was not written' }
    else { Install-HerdrGuide -Folders $folders }
}

Write-Step 'done'
exit 0
