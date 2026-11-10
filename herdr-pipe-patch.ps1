<#
.SYNOPSIS
  Grants extra principals access to the herdr-core Windows pipes, and takes it back.

.DESCRIPTION
  herdr-core's named pipes grant access to SYSTEM and the account that started the
  core only. A client that has to run as another account - a coding agent's sandbox,
  for instance - is refused with "Access is denied (os error 5)".

  The fix is upstream: herdr-core reads HERDR_PIPE_EXTRA_SIDS at start-up and adds
  one allow-ACE per SID to the pipe descriptor. This tool installs a core that has
  that support, sets the variable, restarts the core so it reads it, and proves the
  result by reading the live pipe's access control list back.

  Commands:
    status    what is installed, whether the patch is there, what the pipe grants
    apply     install the patched core if needed, set the variable, restart, verify
    unpatch   put the stock core back, remove the variable, restart, verify
    verify    check the live pipe and (with -Probe) drive it from a sandbox
    build     build a patched core for a version and store it as a payload

  Every step is checked, not assumed: a candidate binary is run as an isolated core
  and its pipe descriptor read back before it is allowed near the real installation.

.EXAMPLE
  .\herdr-pipe-patch.ps1 status
  .\herdr-pipe-patch.ps1 apply -Account CodexSandboxOffline -Account CodexSandboxOnline
  .\herdr-pipe-patch.ps1 apply -DryRun
  .\herdr-pipe-patch.ps1 unpatch
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('status', 'apply', 'unpatch', 'verify', 'build')]
    [string] $Command = 'status',

    # The hc to manage. Default: the one this machine would use (like the app finds it).
    [string] $HcPath,

    # The core session to work on. The default session is named "default".
    [string] $Session = 'default',

    # Principals to grant, as a comma- or semicolon-separated list of SIDs.
    [string] $Sids,

    # Principals to grant, by account name. Their user SIDs are resolved.
    [string[]] $Account,

    # Accounts to grant when neither -Sids nor -Account is given.
    [string] $AccountPattern = 'CodexSandbox*',

    # The version to build a payload for (build command).
    [string] $Version,

    # Print what would happen and change nothing.
    [switch] $DryRun,

    # Only the errors and the warnings.
    [switch] $Quiet,

    # Also run a real client inside a sandbox to prove the pipe is reachable.
    [switch] $Probe,

    # Where releases come from. Defaults to HERDR_RELEASES_URL or releases.herdr.dev.
    [string] $ReleasesUrl,

    # An existing herdr-core clone to build in (build command).
    [string] $Repo,

    # Where the build happens (build command). A temporary directory by default.
    [string] $WorkDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$script:Marker = 'HERDR_PIPE_EXTRA_SIDS'   # the ASCII literal only a patched build carries
$script:EnvVar = 'HERDR_PIPE_EXTRA_SIDS'
$script:ToolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:LogFile = Join-Path $script:ToolRoot 'herdr-pipe-patch.log'

# --------------------------------------------------------------------------- logging

function Write-Log {
    param([string] $Message, [string] $Level = 'info')
    $line = '{0} {1,-5} {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -LiteralPath $script:LogFile -Value $line -ErrorAction SilentlyContinue } catch { }
    if (-not $Quiet -or $Level -eq 'error' -or $Level -eq 'warn') { Write-Host $Message }
}

function Write-Step { param([string] $Message) Write-Log "==> $Message" 'step' }
function Write-Note { param([string] $Message) Write-Log "    $Message" 'info' }
function Write-Warn { param([string] $Message) Write-Log "    ! $Message" 'warn' }
function Write-Fail { param([string] $Message) Write-Log "    x $Message" 'error' }

function Stop-Tool {
    param([string] $Message, [int] $Code = 1)
    Write-Fail $Message
    exit $Code
}

# ------------------------------------------------------------------- native helpers

if (-not ('HerdrPipePatchNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class HerdrPipePatchNative {
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern int GetNamedSecurityInfoW(string name, int objType, uint info,
        out IntPtr owner, out IntPtr group, out IntPtr dacl, out IntPtr sacl, out IntPtr sd);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool ConvertSecurityDescriptorToStringSecurityDescriptorW(
        IntPtr sd, uint flags, uint info, out IntPtr str, out uint len);

    [DllImport("kernel32.dll")]
    static extern IntPtr LocalFree(IntPtr p);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, UIntPtr wParam, string lParam,
        uint flags, uint timeout, out UIntPtr result);

    const uint OWNER = 1, GROUP = 2, DACL = 4;
    const int SE_FILE_OBJECT = 1;

    /// The pipe's security descriptor as an SDDL string, or null when it cannot be read.
    public static string ReadDescriptor(string path) {
        IntPtr owner, group, dacl, sacl, sd;
        int rc = GetNamedSecurityInfoW(path, SE_FILE_OBJECT, OWNER | GROUP | DACL,
            out owner, out group, out dacl, out sacl, out sd);
        if (rc != 0) return null;
        IntPtr str; uint len;
        if (!ConvertSecurityDescriptorToStringSecurityDescriptorW(sd, 1, OWNER | GROUP | DACL, out str, out len)) {
            LocalFree(sd); return null;
        }
        string r = Marshal.PtrToStringUni(str);
        LocalFree(str); LocalFree(sd);
        return r;
    }

    /// Tells every top-level window that the environment changed, so Explorer
    /// (and anything started from it) picks the new value up without a logon.
    public static bool BroadcastEnvironmentChange() {
        UIntPtr result;
        IntPtr ok = SendMessageTimeout(new IntPtr(0xffff), 0x001A, UIntPtr.Zero, "Environment",
            0x0002 /* SMTO_ABORTIFHUNG */, 2000, out result);
        return ok != IntPtr.Zero;
    }
}
'@
}

function Get-PipeDescriptor {
    param([string] $Pipe)
    if (-not $Pipe) { return $null }
    try { return [HerdrPipePatchNative]::ReadDescriptor($Pipe) } catch { return $null }
}

# SDDL writes the well-known principals as short names, so Everyone comes back
# as "WD" and SYSTEM as "SY". They are translated to the SIDs a caller asks with.
$script:SddlWellKnown = @{
    'WD' = 'S-1-1-0'      # Everyone
    'AN' = 'S-1-5-7'      # Anonymous
    'AU' = 'S-1-5-11'     # Authenticated Users
    'IU' = 'S-1-5-4'      # Interactive Users
    'SY' = 'S-1-5-18'     # Local System
    'LS' = 'S-1-5-19'     # Local Service
    'NS' = 'S-1-5-20'     # Network Service
    'BA' = 'S-1-5-32-544' # Administrators
    'BU' = 'S-1-5-32-545' # Users
    'RC' = 'S-1-5-32-555' # Remote Desktop Users
}

function Get-DescriptorSids {
    param([string] $Descriptor)
    $sids = New-Object System.Collections.Generic.List[string]
    if (-not $Descriptor) { return @() }
    foreach ($m in [regex]::Matches($Descriptor, '\([A-Z]+;;[A-Z]+;;;([^)]*)\)')) {
        $sid = $m.Groups[1].Value
        if ($script:SddlWellKnown.ContainsKey($sid)) { $sid = $script:SddlWellKnown[$sid] }
        if ($sid -and -not $sids.Contains($sid)) { $sids.Add($sid) }
    }
    # ToArray, not @($list): PowerShell throws "Argument types do not match"
    # when a generic list goes inside @(), in 5.1 and in 7 alike.
    return $sids.ToArray()
}

function Get-Sha256 {
    param([string] $Path)
    # .NET, not Get-FileHash: that one fails when PowerShell 7 starts 5.1.
    $stream = [IO.File]::OpenRead($Path)
    try {
        return -join ([Security.Cryptography.SHA256]::Create().ComputeHash($stream) |
            ForEach-Object { $_.ToString('x2') })
    } finally { $stream.Close() }
}

# ------------------------------------------------------------------- the environment

function Set-CoreEnvironment {
    <#
      A core that starts inside a Herdr terminal inherits Herdr's variables, and
      HC_SESSION would put it in the wrong session. hc server restart --fresh
      hands the CLI's whole environment to the new core, so these are cleared
      before anything starts or restarts a core.
    #>
    param([string] $ForSession = 'default')

    Remove-Item Env:HC_TERMINAL_ID -ErrorAction SilentlyContinue
    Remove-Item Env:HC_SOCKET -ErrorAction SilentlyContinue
    if ($ForSession -and $ForSession -ne 'default') { $env:HC_SESSION = $ForSession }
    else { Remove-Item Env:HC_SESSION -ErrorAction SilentlyContinue }
}

# ------------------------------------------------------------------- finding things

function Invoke-Native {
    <#
      Runs a program and collects its output and exit code. A program that writes
      to stderr must not end the script: with $ErrorActionPreference = Stop the
      merged stderr would raise a terminating error, and "no core is running" is
      a normal answer, not a failure.
    #>
    param([string] $File, [string[]] $Arguments)
    $previous = $ErrorActionPreference
    $previousEncoding = [Console]::OutputEncoding
    $ErrorActionPreference = 'Continue'
    # Read the output as UTF-8: the console code page would turn a character
    # like the ellipsis in a manual into something else, and the text would no
    # longer match the file it came from.
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $text = ''
    $code = -1
    try {
        # The output has to travel through a pipeline. A program that writes to
        # stdout from a GUI subsystem (the herdr app) panics with "failed
        # printing to stdout" when PowerShell captures its output into a
        # variable instead of a pipeline.
        $text = (& $File @Arguments 2>&1 | Out-String).Trim()
        $code = $LASTEXITCODE
    } catch {
        # A file that cannot be run at all (not an executable) lands here.
        $text = $_.Exception.Message
        $code = -1
    } finally {
        $ErrorActionPreference = $previous
        [Console]::OutputEncoding = $previousEncoding
    }
    return [pscustomobject]@{ ExitCode = $code; Text = $text }
}

function Get-HcVersion {
    param([string] $Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $r = Invoke-Native -File $Path -Arguments @('--version')
    if ($r.ExitCode -ne 0) { return $null }
    foreach ($line in ($r.Text -split "`r?`n")) {
        $t = $line.Trim()
        if ($t -like 'hc *') { return $t }
    }
    return $null
}

function Get-HcPath {
    param([string] $Explicit)

    # An explicitly named hc is used as it is, or the tool stops. Falling back to
    # another installation would quietly patch the wrong thing.
    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit -PathType Leaf)) {
            Stop-Tool "there is no file at $Explicit."
        }
        if (-not (Get-HcVersion $Explicit)) {
            Stop-Tool "$Explicit is not a working hc (its --version does not answer)."
        }
        return (Resolve-Path -LiteralPath $Explicit).Path
    }

    $candidates = New-Object System.Collections.Generic.List[string]

    # The app's own setting wins, like the app's own search (src/core_bin.rs).
    $settings = Join-Path $env:USERPROFILE '.config\herdr-app\settings.json'
    if (Test-Path -LiteralPath $settings) {
        try {
            $json = Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json
            if (($json.PSObject.Properties.Name -contains 'core') -and $json.core) {
                $candidates.Add(($json.core -replace '^~', $env:USERPROFILE))
            }
        } catch { }
    }

    foreach ($dir in ($env:PATH -split ';')) {
        if (-not $dir) { continue }
        try {
            $candidates.Add((Join-Path $dir 'herdr-core.exe'))
            $candidates.Add((Join-Path $dir 'hc.exe'))
        } catch { }
    }

    foreach ($p in @(
            (Join-Path $env:LOCALAPPDATA 'Programs\herdr-core\herdr-core.exe'),
            (Join-Path $env:LOCALAPPDATA 'Programs\herdr-core\hc.exe'),
            (Join-Path $env:USERPROFILE '.cargo\bin\herdr-core.exe'),
            (Join-Path $env:USERPROFILE '.cargo\bin\hc.exe'))) {
        $candidates.Add($p)
    }

    foreach ($c in $candidates) {
        if (-not $c) { continue }
        try {
            if (Test-Path -LiteralPath $c -PathType Leaf) {
                if (Get-HcVersion $c) { return (Resolve-Path -LiteralPath $c).Path }
            }
        } catch { }
    }
    return $null
}

function Invoke-Hc {
    param([string] $Hc, [string[]] $Arguments)
    $r = Invoke-Native -File $Hc -Arguments $Arguments
    $json = $null
    try { $json = $r.Text | ConvertFrom-Json } catch { }
    return [pscustomobject]@{ ExitCode = $r.ExitCode; Text = $r.Text; Json = $json }
}

function Get-CoreStatus {
    param([string] $Hc)
    if (-not $Hc) { return $null }
    # On Windows `hc server status` never starts a core (platform::status_may_start_core
    # is false there), so this is safe to call when nothing runs.
    $r = Invoke-Hc $Hc @('server', 'status', '--json')
    if ($r.ExitCode -ne 0) { return $null }
    return $r.Json
}

function Test-PatchedBinary {
    param([string] $Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $text = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($Path))
        return $text.IndexOf($script:Marker, [StringComparison]::Ordinal) -ge 0
    } catch { return $false }
}

function Get-StateDir {
    param([string] $Name)
    $stateRoot = $env:LOCALAPPDATA
    if ($env:XDG_STATE_HOME) { $stateRoot = $env:XDG_STATE_HOME }
    return (Join-Path (Join-Path $stateRoot 'herdr-core') $Name)
}

function Get-PipePath {
    param([string] $Name)
    # The serving core writes its pipe path into core.lock (server.rs).
    $lock = Join-Path (Get-StateDir $Name) 'core.lock'
    if (Test-Path -LiteralPath $lock) {
        try {
            $raw = [IO.File]::ReadAllText($lock)
            if ($raw -and $raw.StartsWith('\\.\pipe\')) { return $raw.Trim() }
        } catch { }
    }
    # Otherwise the name the core would use (windows.rs endpoints()).
    $user = ($env:USERNAME -replace '[^A-Za-z0-9]', '')
    return "\\.\pipe\herdr-core-$user-$Name.sock"
}

function Get-LocalAccountNames {
    $names = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($u in (Get-LocalUser -ErrorAction SilentlyContinue)) { $names.Add($u.Name) }
    } catch { }
    if ($names.Count -eq 0) {
        try {
            foreach ($u in (Get-CimInstance Win32_UserAccount -Filter 'LocalAccount=True' -ErrorAction SilentlyContinue)) {
                $names.Add($u.Name)
            }
        } catch { }
    }
    # ToArray, not @($list): PowerShell throws "Argument types do not match"
    # when a generic list goes inside @(), in 5.1 and in 7 alike.
    return $names.ToArray()
}

function Resolve-AccountSid {
    param([string] $Name)
    try {
        $account = New-Object System.Security.Principal.NTAccount($Name)
        return $account.Translate([System.Security.Principal.SecurityIdentifier]).Value
    } catch { return $null }
}

function Get-LocalGroupSids {
    $sids = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($g in (Get-LocalGroup -ErrorAction SilentlyContinue)) { $sids.Add($g.SID.Value) }
    } catch { }
    if ($sids.Count -eq 0) {
        try {
            foreach ($g in (Get-CimInstance Win32_Group -ErrorAction SilentlyContinue)) {
                $sid = $g.SID
                if ($sid -match '^S-1-5-21-') { $sids.Add($sid) }
            }
        } catch { }
    }
    # ToArray, not @($list): PowerShell throws "Argument types do not match"
    # when a generic list goes inside @(), in 5.1 and in 7 alike.
    return $sids.ToArray()
}

function Resolve-TargetSids {
    $wanted = New-Object System.Collections.Generic.List[string]
    $groupSids = @(Get-LocalGroupSids)

    if ($Sids) {
        foreach ($s in ($Sids -split '[,;]')) {
            $t = $s.Trim()
            if (-not $t) { continue }
            if ($t -notmatch '^S-1-') { Stop-Tool "'$t' is not a SID. Give SIDs like S-1-5-21-...-1009." }
            if ($groupSids -contains $t) {
                Write-Warn "$t is a local group. An access check honours a restricted token's user SID but not its group SIDs, so a group grants it nothing. Grant the account's own SID instead."
            }
            $wanted.Add($t)
        }
    }

    foreach ($a in $Account) {
        $sid = Resolve-AccountSid $a
        if (-not $sid) {
            # The account does not exist here yet - usually the elevated sandbox
            # has not been provisioned. Stopping here would leave the person
            # without the one command that fixes it.
            Write-Warn "there is no account '$a' on this machine."
            Write-Warn 'the elevated sandbox creates it; run this in an elevated terminal:'
            Write-Warn '  codex sandbox setup --elevated --current-user'
            continue
        }
        Write-Note "$a -> $sid"
        $wanted.Add($sid)
    }

    # The pattern is the fallback, not the answer: when accounts were named
    # and none of them exists here, granting the pattern's accounts instead
    # would be granting something nobody asked for.
    if ($wanted.Count -eq 0 -and @($Account).Count -eq 0) {
        foreach ($n in @(Get-LocalAccountNames)) {
            if ($n -like $AccountPattern) {
                $sid = Resolve-AccountSid $n
                if ($sid) { Write-Note "$n -> $sid (matched '$AccountPattern')"; $wanted.Add($sid) }
            }
        }
    }

    $unique = New-Object System.Collections.Generic.List[string]
    foreach ($s in $wanted) { if (-not $unique.Contains($s)) { $unique.Add($s) } }
    # ToArray, not @($list): PowerShell throws "Argument types do not match"
    # when a generic list goes inside @(), in 5.1 and in 7 alike.
    return $unique.ToArray()
}

# ------------------------------------------------------------------- changing things

function Set-UserEnvironment {
    param([string] $Name, [string] $Value)
    [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
    try { [HerdrPipePatchNative]::BroadcastEnvironmentChange() | Out-Null } catch { }
}

function Restart-Core {
    param([string] $Hc, [hashtable] $Environment, [string] $ForSession = 'default', [switch] $Fresh)

    Set-CoreEnvironment -ForSession $ForSession
    foreach ($k in $Environment.Keys) { Set-Item -Path "Env:$k" -Value $Environment[$k] }

    if ($Fresh) {
        $r = Invoke-Hc $Hc @('server', 'restart', '--fresh', '--json')
        if ($r.ExitCode -eq 0) {
            # With no core running, --fresh only stores the environment for the
            # next start; the core itself still has to be started.
            Start-Sleep -Milliseconds 900
            if (Get-CoreStatus $Hc) {
                return [pscustomobject]@{ Ok = $true; How = 'server restart --fresh'; Result = $r }
            }
            Write-Note 'no core was running; starting one with the stored environment'
            $start = Invoke-Hc $Hc @('server', 'start', '--json')
            if ($start.ExitCode -ne 0) { return [pscustomobject]@{ Ok = $false; How = 'server start'; Result = $start } }
            return [pscustomobject]@{ Ok = $true; How = 'server restart --fresh; server start'; Result = $start }
        }
        Write-Note "restart --fresh was refused: $($r.Text)"
    }

    # The running core keeps the environment it started with, so a plain restart
    # cannot pick up a new variable. Stop it and start it from here instead: the
    # holders keep the terminals running either way.
    Write-Note 'restarting the core (stop, then start it from this process)'
    $stop = Invoke-Hc $Hc @('server', 'stop', '--json')
    Start-Sleep -Milliseconds 1200
    $start = Invoke-Hc $Hc @('server', 'start', '--json')
    if ($start.ExitCode -ne 0) { return [pscustomobject]@{ Ok = $false; How = 'server stop; server start'; Result = $start } }
    return [pscustomobject]@{ Ok = $true; How = 'server stop; server start'; Result = $start }
}

function Test-CandidateBinary {
    <#
      Runs a candidate core as an isolated core and reads the pipe descriptor it
      creates. A binary that merely contains the marker string but does not grant
      the SIDs fails here, and is never installed.
    #>
    param([string] $Candidate, [string[]] $GrantSids)

    $probe = 'hpp-probe-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $savedSession = $env:HC_SESSION
    $savedSids = $env:HERDR_PIPE_EXTRA_SIDS
    try {
        $env:HC_SESSION = $probe
        $env:HERDR_PIPE_EXTRA_SIDS = ($GrantSids -join ';')
        Remove-Item Env:HC_TERMINAL_ID -ErrorAction SilentlyContinue
        Remove-Item Env:HC_SOCKET -ErrorAction SilentlyContinue

        Invoke-Native -File $Candidate -Arguments @('server', 'start', '--json') | Out-Null

        # The core needs a moment to create its pipe. A slow machine (a CI
        # runner) needs more than a fixed sleep, so the descriptor is read
        # until it answers or half a minute is up.
        $pipe = Get-PipePath $probe
        $descriptor = $null
        for ($i = 0; $i -lt 60 -and -not $descriptor; $i++) {
            $descriptor = Get-PipeDescriptor $pipe
            if (-not $descriptor) { Start-Sleep -Milliseconds 500 }
        }
        $granted = @(Get-DescriptorSids $descriptor)
        $missing = @()
        foreach ($s in $GrantSids) { if (-not $granted.Contains($s)) { $missing += $s } }

        Invoke-Native -File $Candidate -Arguments @('server', 'stop', '--json') | Out-Null
        return [pscustomobject]@{
            Ok         = ($missing.Count -eq 0)
            Pipe       = $pipe
            Descriptor = $descriptor
            Missing    = $missing
        }
    } finally {
        if ($null -eq $savedSession) { Remove-Item Env:HC_SESSION -ErrorAction SilentlyContinue }
        else { $env:HC_SESSION = $savedSession }
        if ($null -eq $savedSids) { Remove-Item Env:HERDR_PIPE_EXTRA_SIDS -ErrorAction SilentlyContinue }
        else { $env:HERDR_PIPE_EXTRA_SIDS = $savedSids }
        Start-Sleep -Milliseconds 400
        Remove-Item -LiteralPath (Get-StateDir $probe) -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Probe {
    <#
      The end-to-end proof: a client that runs as another account, driving the
      core. This is how the refusal was reproduced, and how the fix is shown.
    #>
    param([string] $Hc)
    Write-Step 'probe: driving the core from a sandbox'
    $codex = Get-Command codex -ErrorAction SilentlyContinue
    if (-not $codex) {
        # The probe was asked for and could not run. A probe that did not run
        # is not a proof, so the command must not report success.
        Stop-Tool 'the sandbox probe could not run: codex is not on PATH. Install codex, or leave -Probe out.'
    }
    Write-Note "codex: $($codex.Source)"
    $r = Invoke-Native -File $codex.Source -Arguments @('sandbox', '-c', 'windows.sandbox=elevated', $Hc, 'ls', '--json')
    $code = $r.ExitCode
    $text = $r.Text
    if ($code -eq 0) {
        Write-Note 'the sandboxed client reached the core'
        $lines = @($text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 2)
        foreach ($l in $lines) { Write-Note "  $l" }
    } else {
        Write-Fail "the sandboxed client failed (exit $code): $text"
        exit 1
    }
}

function Get-PayloadPath {
    param([string] $Version)
    return (Join-Path (Join-Path (Join-Path $script:ToolRoot 'payload') $Version) 'herdr-core.exe')
}

function Get-PayloadHashPath {
    param([string] $Version)
    return (Get-PayloadPath $Version) + '.sha256'
}

function Install-Core {
    param([string] $Hc, [string] $Candidate)
    $r = Invoke-Hc $Hc @('update', '--from', $Candidate, '--json')
    if ($r.ExitCode -ne 0) {
        if ($r.Text -match 'older than this') {
            Stop-Tool "the core refuses the candidate: $($r.Text)"
        }
        Stop-Tool "hc update --from failed: $($r.Text)"
    }
    Write-Note "installed: $($r.Text)"
    return $r
}

function Get-StockCore {
    <#
      The released core for a version, downloaded from the release service and
      checked against the checksum the manifest carries. The manifest is not
      signed, so this proves the download is intact, not who published it.
    #>
    param([string] $WantedVersion, [string] $Base, [string] $Scratch)

    $manifestUrl = "$Base/core/$WantedVersion/manifest.json"
    Write-Note "reading $manifestUrl"
    try {
        $manifest = Invoke-RestMethod -Uri $manifestUrl -UseBasicParsing
    } catch {
        Stop-Tool "cannot read the release manifest: $($_.Exception.Message)"
    }
    $target = $manifest.targets.PSObject.Properties |
        Where-Object { $_.Name -eq 'windows-x86_64' } |
        Select-Object -First 1
    if (-not $target) { Stop-Tool "the $WantedVersion release has no windows-x86_64 build." }

    $dir = Join-Path $Scratch "stock-$WantedVersion"
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    $zip = Join-Path $dir 'release.zip'
    & curl.exe -fsSL --retry 2 --connect-timeout 10 -o $zip $target.Value.url
    if ($LASTEXITCODE -ne 0) { Stop-Tool "the download of $WantedVersion failed." }

    $want = $target.Value.sha256.ToLower()
    $got = Get-Sha256 $zip
    if ($got -ne $want) { Stop-Tool "the download of $WantedVersion is damaged (checksum $got, expected $want)." }
    Write-Note "checksum ok ($got)"

    & "$env:SystemRoot\System32\tar.exe" -xf $zip -C $dir
    if ($LASTEXITCODE -ne 0) { Stop-Tool 'the release archive could not be unpacked.' }
    $exe = Join-Path $dir 'herdr-core.exe'
    if (-not (Test-Path -LiteralPath $exe)) { Stop-Tool 'the release archive holds no herdr-core.exe.' }
    return $exe
}

function Find-Cargo {
    <#
      cargo on PATH, else a rustup installation that is not on PATH. The rustup
      proxies need RUSTUP_HOME and CARGO_HOME to find their toolchain, so they
      are set along with the binary.
    #>
    $cmd = Get-Command cargo -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($cargoHome in @(
            (Join-Path $env:USERPROFILE '.cargo'),
            (Join-Path $env:LOCALAPPDATA 'puccinialin\puccinialin\Cache\cargo'))) {
        $exe = Join-Path $cargoHome 'bin\cargo.exe'
        if (Test-Path -LiteralPath $exe) {
            $env:CARGO_HOME = $cargoHome
            $rustup = Join-Path (Split-Path -Parent $cargoHome) 'rustup'
            if (Test-Path -LiteralPath $rustup) { $env:RUSTUP_HOME = $rustup }
            return $exe
        }
    }
    return $null
}

function Build-Payload {
    param([string] $Version, [string[]] $GrantSids)

    $patch = Join-Path (Join-Path $script:ToolRoot 'patches') 'herdr-core-pipe-extra-sids.patch'
    if (-not (Test-Path -LiteralPath $patch)) { Stop-Tool "no patch at $patch" }

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Stop-Tool "'git' is not on PATH. Building a patched core needs git, Rust (cargo) and Zig 0.16."
    }
    $cargo = Find-Cargo
    if (-not $cargo) {
        Stop-Tool "'cargo' was not found. Building a patched core needs Rust; put cargo on PATH, or install it with rustup."
    }
    Write-Note "cargo: $cargo"
    $zig = $null
    if ($env:ZIG -and (Test-Path -LiteralPath $env:ZIG)) { $zig = $env:ZIG }
    elseif (Get-Command zig -ErrorAction SilentlyContinue) { $zig = (Get-Command zig).Source }
    else {
        $candidate = Join-Path $env:LOCALAPPDATA 'Temp\zig-x86_64-windows-0.16.0\zig.exe'
        if (Test-Path -LiteralPath $candidate) { $zig = $candidate }
    }
    if (-not $zig) {
        Stop-Tool 'Zig 0.16 was not found. The vendored ghostty-vt needs it: set ZIG to zig.exe, or put zig on PATH.'
    }
    Write-Note "zig: $zig"

    $tree = $Repo
    if (-not $tree) {
        $scratch = if ($WorkDir) { $WorkDir } else { Join-Path $env:TEMP ("hpp-build-" + [Guid]::NewGuid().ToString('N').Substring(0, 8)) }
        $tree = Join-Path $scratch 'herdr-core'
        Write-Note "cloning herdrdev/herdr-core v$Version into $tree"
        & git clone --depth 1 --branch "v$Version" https://github.com/herdrdev/herdr-core.git $tree
        if ($LASTEXITCODE -ne 0) { Stop-Tool "the clone of v$Version failed." }
    }
    Push-Location $tree
    try {
        Write-Note 'fetching the vendored ghostty-vt submodule'
        & git submodule update --init --depth 1
        Write-Note 'checking the patch applies'
        $check = Invoke-Native -File 'git' -Arguments @('apply', '--check', $patch)
        if ($check.ExitCode -ne 0) {
            # The patch stops applying when upstream merges the change. Then the
            # source already carries the feature, and the build is a stock build
            # that happens to have it.
            $source = Join-Path $tree 'crates\herdr-core\src\platform\windows.rs'
            $merged = (Test-Path -LiteralPath $source) -and
                      (Select-String -LiteralPath $source -Pattern $script:Marker -Quiet)
            if ($merged) {
                Write-Note "the patch does not apply, but the source already carries $script:Marker - upstream has merged it"
            } else {
                Stop-Tool "the patch does not apply to v$Version. It may need rebasing onto that tag."
            }
        } else {
            & git apply $patch
        }
        Write-Note 'building (this takes a few minutes)'
        $env:ZIG = $zig
        & $cargo build --release -p herdr-core
        if ($LASTEXITCODE -ne 0) { Stop-Tool 'the build failed.' }
    } finally {
        Pop-Location
    }

    $built = Join-Path $tree 'target\release\herdr-core.exe'
    if (-not (Test-Path -LiteralPath $built)) { Stop-Tool 'the build produced no binary.' }

    # Probe the built binary before it becomes the payload: a binary that does
    # not grant the SIDs must never be published.
    $check = Test-CandidateBinary -Candidate $built -GrantSids $GrantSids
    if (-not $check.Ok) {
        Stop-Tool "the freshly built core does not grant $($check.Missing -join ', '). Something is wrong with the build."
    }
    Write-Note 'the new build grants the SIDs when run as an isolated core'

    $dest = Get-PayloadPath $Version
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
    Copy-Item -LiteralPath $built -Destination $dest -Force
    $hash = Get-Sha256 $dest
    Set-Content -LiteralPath (Get-PayloadHashPath $Version) -Value ($hash + '  herdr-core.exe') -Encoding ascii

    $commit = (& git -C $tree rev-parse HEAD 2>$null | Out-String).Trim()
    @(
        "version      : $Version",
        'source       : https://github.com/herdrdev/herdr-core',
        "commit       : $commit",
        "patch        : $(Split-Path -Leaf $patch)",
        "patch sha256 : $(Get-Sha256 $patch)",
        "binary sha256: $hash",
        "built        : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "rustc        : $((& (Join-Path (Split-Path -Parent $cargo) 'rustc.exe') --version 2>$null) -join '')",
        "zig          : $zig",
        '',
        'Rust embeds a path-dependent metadata hash, so a rebuild of the same source',
        'is not byte-identical. Compare the behaviour, not the bytes.'
    ) | Set-Content -LiteralPath (Join-Path (Split-Path -Parent $dest) 'BUILD.txt') -Encoding utf8

    Write-Note "payload written: $dest"
    Write-Note "sha256: $hash"
    return $dest
}

function Get-PatchedCore {
    <#
      A patched core for the wanted version: the bundled payload when it is there,
      otherwise one built from the tag. Either way it is checked before it is used.
    #>
    param([string] $WantedVersion, [string[]] $GrantSids, [switch] $AllowBuild)

    $payload = Get-PayloadPath $WantedVersion
    $hashFile = Get-PayloadHashPath $WantedVersion

    if (Test-Path -LiteralPath $payload -PathType Leaf) {
        Write-Note "using the bundled payload $payload"
        if (Test-Path -LiteralPath $hashFile) {
            $want = ((Get-Content -LiteralPath $hashFile -Raw) -split '\s+')[0].Trim().ToLower()
            $got = Get-Sha256 $payload
            if ($got -ne $want) {
                Stop-Tool "the bundled payload's checksum does not match ($got, expected $want). It was changed or damaged; get a fresh copy."
            }
            Write-Note "checksum ok ($got)"
        } else {
            Write-Warn 'the payload has no .sha256 beside it; only its behaviour is checked'
        }
    } elseif ($AllowBuild) {
        Write-Note "no bundled payload for $WantedVersion; building one from the tag"
        return (Build-Payload -Version $WantedVersion -GrantSids $GrantSids)
    } else {
        Stop-Tool "there is no patched core for $WantedVersion. Run: .\herdr-pipe-patch.ps1 build -Version $WantedVersion"
    }

    if (-not (Test-PatchedBinary $payload)) {
        Stop-Tool "the payload at $payload does not carry the $script:Marker support. It is not a patched core."
    }

    $check = Test-CandidateBinary -Candidate $payload -GrantSids $GrantSids
    if (-not $check.Ok) {
        Stop-Tool "the payload does not grant $($check.Missing -join ', ') on this machine. Refusing to install it."
    }
    Write-Note 'the payload grants the SIDs when run as an isolated core'
    return $payload
}

# ------------------------------------------------------------------------ codex side

function Get-CodexHome { return (Join-Path $env:USERPROFILE '.codex') }

function Get-AgentHome {
    <#
      Where an agent keeps its skills. Codex reads ~/.codex/skills, Claude Code
      reads ~/.claude/skills. A guide that is right for one agent and missing
      for the other leaves that session without one - and a session without the
      guide stops, saying it is not inside Herdr.
    #>
    param([ValidateSet('codex', 'claude')] [string] $Agent)
    if ($Agent -eq 'codex') { return (Get-CodexHome) }
    return (Join-Path $env:USERPROFILE '.claude')
}

function Get-CodexConfigValue {
    <#
      One key out of ~/.codex/config.toml. It is TOML, but only a few keys matter
      here, and they are plain `key = "value"` lines inside a section.
    #>
    param([string] $Section, [string] $Key)
    $path = Join-Path (Get-CodexHome) 'config.toml'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $lines = [IO.File]::ReadAllLines($path)
    $inSection = ($Section -eq '')
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $t = $lines[$i].Trim()
        if ($t -match '^\[(.+?)\]$') {
            if ($inSection) { return $null }
            $inSection = ($Matches[1].Trim() -eq $Section)
            continue
        }
        if (-not $inSection) { continue }
        if ($t -match "^$([regex]::Escape($Key))\s*=\s*(.+)$") {
            return $Matches[1].Trim().Trim('"').Trim("'")
        }
    }
    return $null
}

function Set-CodexConfigValue {
    <#
      Sets one key in ~/.codex/config.toml, keeping the file's own line endings
      and byte order mark, and keeping a copy of the old one beside it.
    #>
    param([string] $Section, [string] $Key, [string] $Value)
    $path = Join-Path (Get-CodexHome) 'config.toml'
    if (-not (Test-Path -LiteralPath $path)) { return $false }

    $text = [IO.File]::ReadAllText($path)
    $eol = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $endsWithNewline = $text.EndsWith("`n")
    $lines = @($text -split "`r?`n")

    $sectionIndex = -1
    $sectionEnd = $lines.Count
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $t = $lines[$i].Trim()
        if ($t -match '^\[(.+?)\]$') {
            if ($sectionIndex -ge 0) { $sectionEnd = $i; break }
            if ($Matches[1].Trim() -eq $Section) { $sectionIndex = $i }
        }
    }

    if ($sectionIndex -lt 0) {
        $new = @($lines) + @('', "[$Section]", "$Key = $Value")
    } else {
        $keyLine = -1
        for ($i = $sectionIndex + 1; $i -lt $sectionEnd; $i++) {
            if ($lines[$i] -match "^\s*$([regex]::Escape($Key))\s*=") { $keyLine = $i; break }
        }
        if ($keyLine -ge 0) {
            $lines[$keyLine] = "$Key = $Value"
            $new = $lines
        } else {
            $new = @()
            $new += $lines[0..$sectionIndex]
            $new += "$Key = $Value"
            if ($sectionEnd -gt $sectionIndex + 1) { $new += $lines[($sectionIndex + 1)..($sectionEnd - 1)] }
            if ($sectionEnd -lt $lines.Count) { $new += $lines[$sectionEnd..($lines.Count - 1)] }
        }
    }

    $backup = "$path.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item -LiteralPath $path -Destination $backup -Force
    $out = ($new -join $eol)
    if ($endsWithNewline) { $out += $eol }
    [IO.File]::WriteAllText($path, $out, [System.Text.UTF8Encoding]::new($false))
    Write-Note "saved the old config as $backup"
    return $true
}

function Get-CodexSandboxAccounts {
    $list = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($u in (Get-LocalUser -ErrorAction SilentlyContinue)) {
            if ($u.Name -like 'CodexSandbox*') {
                $list.Add([pscustomobject]@{ Name = $u.Name; SID = $u.SID.Value; Enabled = $u.Enabled })
            }
        }
    } catch { }
    if ($list.Count -eq 0) {
        try {
            foreach ($u in (Get-CimInstance Win32_UserAccount -Filter 'LocalAccount=True' -ErrorAction SilentlyContinue)) {
                if ($u.Name -like 'CodexSandbox*') {
                    $list.Add([pscustomobject]@{
                        Name = $u.Name
                        SID = ('S-1-5-21-' + ($u.SID -replace '^S-1-5-21-', ''))
                        Enabled = $true
                    })
                }
            }
        } catch { }
    }
    # ToArray, not @($list): PowerShell throws "Argument types do not match"
    # when a generic list goes inside @(), in 5.1 and in 7 alike.
    return $list.ToArray()
}

function Get-CodexSandboxService {
    try {
        $s = Get-Service -Name 'CodexSandboxService.OpenAI.Codex' -ErrorAction SilentlyContinue
        if ($s) { return [pscustomobject]@{ Name = $s.Name; Status = $s.Status.ToString() } }
    } catch { }
    return $null
}

function Get-CodexDaemonState {
    $cmd = Get-Command codex -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }
    $r = Invoke-Native -File $cmd.Source -Arguments @('app-server', 'daemon', 'version')
    if ($r.ExitCode -ne 0) { return $null }
    try { return ($r.Text | ConvertFrom-Json) } catch { return $null }
}

function Get-HerdrAppPath {
    $cmd = Get-Command herdr-app -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $p = Join-Path $env:LOCALAPPDATA 'Programs\herdr-app\herdr-app.exe'
    if (Test-Path -LiteralPath $p) { return $p }
    return $null
}

function Get-CodexSkill {
    <#
      The Herdr guide an agent reads: is it there, does it gate on the right
      thing, does it carry the manuals the installed binaries print, and is it
      the head for this side of the machine?
    #>
    param([string] $Hc, [string] $Agent = 'codex')
    $path = Join-Path (Join-Path (Get-AgentHome -Agent $Agent) 'skills\herdr') 'SKILL.md'
    $state = [pscustomobject]@{
        Agent         = $Agent
        Path          = $path
        Exists        = $false
        GatesTerminal = $false
        GatesHerdrEnv = $false
        HcUpToDate    = $false
        AppUpToDate   = $false
        MentionsWinHc = $false
        Wrapper       = ''
        Text          = ''
    }
    if (-not (Test-Path -LiteralPath $path)) { return $state }
    $text = [IO.File]::ReadAllText($path)
    $state.Exists = $true
    $state.Text = $text
    $state.GatesTerminal = $text.Contains('test -n "${HC_TERMINAL_ID:-}"')
    $state.GatesHerdrEnv = $text.Contains('"${HERDR_ENV:-}" = 1')
    # The WSL head tells the agent to drive the Windows core with win-hc. On
    # this side that is the wrong head: the guide would send the agent to a
    # command that does not exist here.
    $state.MentionsWinHc = $text.Contains('win-hc')

    $index = $text.IndexOf('# hc manual (herdr-core)')
    if ($index -gt 0) { $state.Wrapper = $text.Substring(0, $index) }

    $norm = { param($s) ($s -replace "`r`n", "`n").Trim() }
    if ($Hc -and (Test-Path -LiteralPath $Hc -PathType Leaf)) {
        $r = Invoke-Native -File $Hc -Arguments @('--skill')
        if ($r.ExitCode -eq 0 -and $r.Text) {
            $state.HcUpToDate = (& $norm $text).Contains((& $norm $r.Text))
        }
    }
    $app = Get-HerdrAppPath
    if ($app) {
        $r = Invoke-Native -File $app -Arguments @('--skill')
        if ($r.ExitCode -eq 0 -and $r.Text) {
            $state.AppUpToDate = (& $norm $text).Contains((& $norm $r.Text))
        }
    }
    return $state
}

function Update-CodexSkill {
    <#
      Rebuilds the codex skill from the manuals the installed binaries print now.
      The part in front of the manuals - the frontmatter, the gate and the note
      about HERDR_ENV - is a local addition, so it is taken from the installed
      file rather than written again here.
    #>
    param([string] $Hc, [string] $Agent = 'codex')
    $skill = Get-CodexSkill -Hc $Hc -Agent $Agent
    if (-not $skill.Exists) { return $false }
    if (-not $skill.Wrapper) {
        Write-Fail 'the installed skill has no recognisable head; not rewriting it.'
        return $false
    }
    $head = $skill.Wrapper
    if ($skill.MentionsWinHc) {
        # The installed guide carries the WSL head. The head for this side is
        # in the tool's own assets folder.
        $windowsHead = Join-Path (Join-Path $script:ToolRoot 'assets') 'herdr-skill-wrapper.md'
        if (Test-Path -LiteralPath $windowsHead) {
            $head = ([IO.File]::ReadAllText($windowsHead) -replace "`r`n", "`n").Trim()
            Write-Note 'the installed guide carried the WSL head; the head for this side replaces it'
        } else {
            Write-Warn 'the installed guide carries the WSL head and the head for this side is not beside the tool; the head is kept as it is'
        }
    }
    $app = Get-HerdrAppPath
    if (-not $app) { Write-Fail 'herdr-app was not found, so the app manual cannot be read.'; return $false }

    $hcText = (Invoke-Native -File $Hc -Arguments @('--skill')).Text
    $appText = (Invoke-Native -File $app -Arguments @('--skill')).Text
    if (-not $hcText -or -not $appText) { Write-Fail 'a manual could not be read; not rewriting the skill.'; return $false }

    $new = $head + ($hcText -replace "`r`n", "`n").Trim() + "`n---`n`n" + ($appText -replace "`r`n", "`n").Trim() + "`n"
    $backup = $skill.Path + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item -LiteralPath $skill.Path -Destination $backup -Force
    [IO.File]::WriteAllText($skill.Path, $new, [System.Text.UTF8Encoding]::new($false))
    Write-Note "saved the old skill as $backup"
    return $true
}

function Get-SkillProblems {
    <#
      What one agent's guide looks like, and what is wrong with it. Codex reads
      ~/.codex/skills, Claude Code reads ~/.claude/skills: both are checked,
      because a guide that is right for one and missing for the other leaves
      that session without one.
    #>
    param([string] $Agent, $Skill)
    $problems = New-Object System.Collections.Generic.List[string]
    Write-Note "skill           : $(if ($Skill.Exists) { $Skill.Path } else { 'not installed' })"
    if (-not $Skill.Exists) {
        $problems.Add("$Agent has no herdr skill installed")
        return $problems
    }
    Write-Note "gate            : $(if ($Skill.GatesHerdrEnv) { 'HERDR_ENV (the 0.9.5 guide)' } elseif ($Skill.GatesTerminal) { 'HC_TERMINAL_ID' } else { 'unknown' })"
    Write-Note "hc manual       : $(if ($Skill.HcUpToDate) { 'up to date' } else { 'older than the installed core' })"
    Write-Note "app manual      : $(if ($Skill.AppUpToDate) { 'up to date' } else { 'older than the installed app' })"
    if ($Skill.GatesHerdrEnv) { $problems.Add("the $Agent skill gates on HERDR_ENV; that guide belongs to the older herdr and stops the agent") }
    if (-not $Skill.GatesTerminal) { $problems.Add("the $Agent skill does not gate on HC_TERMINAL_ID") }
    if (-not $Skill.HcUpToDate) { $problems.Add("the $Agent skill carries an older hc manual than the installed core") }
    if (-not $Skill.AppUpToDate) { $problems.Add("the $Agent skill carries an older herdr-app manual than the installed app") }
    if ($Skill.MentionsWinHc) { $problems.Add("the $Agent skill on this side carries the WSL head; it sends the agent to win-hc, which does not exist here") }
    return $problems
}

function Show-Codex {
    <#
      The codex side of the same question: does a sandboxed codex on this machine
      run as an account the pipe grants, with the guides and settings it needs?
    #>
    param([string] $Hc, [string[]] $GrantSids)

    Write-Log 'codex' 'step'
    $problems = New-Object System.Collections.Generic.List[string]

    $cmd = Get-Command codex -ErrorAction SilentlyContinue
    if (-not $cmd) {
        Write-Note 'codex           : not on PATH - nothing to check on the codex side'
        return [pscustomobject]@{ Problems = $problems; Accounts = @(); Service = $null; Skill = $null; Daemon = $null }
    }
    $version = (Invoke-Native -File $cmd.Source -Arguments @('--version')).Text
    Write-Note "codex           : $version"

    $sandboxMode = Get-CodexConfigValue -Section '' -Key 'sandbox_mode'
    $windowsSandbox = Get-CodexConfigValue -Section 'windows' -Key 'sandbox'
    $daemonAutoStart = Get-CodexConfigValue -Section 'features' -Key 'daemon_auto_start'
    Write-Note "config.toml     : $(Join-Path (Get-CodexHome) 'config.toml')"
    Write-Note "sandbox_mode    : $(if ($sandboxMode) { $sandboxMode } else { 'not set' })"
    Write-Note "windows.sandbox : $(if ($windowsSandbox) { $windowsSandbox } else { 'not set' })"
    Write-Note "daemon_auto_start: $(if ($daemonAutoStart) { $daemonAutoStart } else { 'not set' })"

    if ($windowsSandbox -ne 'elevated') {
        $problems.Add("codex runs its sandbox as '$windowsSandbox'; only the elevated sandbox runs as a separate account, and only that one can be granted")
    }
    if ($daemonAutoStart -ne 'false') {
        $problems.Add('codex daemon_auto_start is not false: a shared app-server daemon freezes the pane environment')
    }

    $accounts = @(Get-CodexSandboxAccounts)
    $service = Get-CodexSandboxService
    Write-Note ('sandbox accounts: ' + $(if ($accounts.Count -gt 0) { ($accounts | ForEach-Object { $_.Name }) -join ', ' } else { 'none' }))
    Write-Note ('sandbox service : ' + $(if ($service) { "$($service.Name) ($($service.Status))" } else { 'not installed' }))
    if ($windowsSandbox -eq 'elevated' -and ($accounts.Count -eq 0 -or -not $service)) {
        $problems.Add('the elevated sandbox is not provisioned: run `codex sandbox setup --elevated --current-user` in an elevated terminal')
    }

    $ungranted = @()
    foreach ($a in $accounts) {
        if ($GrantSids.Count -gt 0 -and -not $GrantSids.Contains($a.SID)) { $ungranted += $a.Name }
    }
    if ($ungranted.Count -gt 0) {
        $problems.Add("the pipe does not grant the sandbox accounts: $($ungranted -join ', ')")
    }

    $daemon = Get-CodexDaemonState
    if ($daemon) {
        Write-Note "app-server      : $($daemon.status)"
        if ($daemon.status -eq 'running') {
            Write-Warn 'a shared app-server daemon is running. Codex sessions started without --no-daemon use it, and it froze the pane environment before.'
        }
    }

    $skill = Get-CodexSkill -Hc $Hc -Agent 'codex'
    foreach ($problem in (Get-SkillProblems -Agent 'codex' -Skill $skill)) { $problems.Add($problem) }

    Write-Log 'claude code' 'step'
    $claudeSkill = Get-CodexSkill -Hc $Hc -Agent 'claude'
    foreach ($problem in (Get-SkillProblems -Agent 'Claude Code' -Skill $claudeSkill)) { $problems.Add($problem) }

    return [pscustomobject]@{
        Problems = $problems
        Accounts = $accounts
        Service  = $service
        Skill    = $skill
        Daemon   = $daemon
    }
}

function Repair-Codex {
    <#
      The codex-side fixes that are safe to make: two keys in config.toml and a
      skill that carries the manuals the installed binaries print. The sandbox
      provisioning and the running daemon are left to the person: the first needs
      an elevated terminal, the second would end other people's sessions.
    #>
    param([string] $Hc, [string[]] $GrantSids, [switch] $DryRun)

    $accounts = @(Get-CodexSandboxAccounts)
    $service = Get-CodexSandboxService
    $haveAccounts = ($accounts.Count -gt 0 -and $service)
    $configPath = Join-Path (Get-CodexHome) 'config.toml'
    $haveConfig = Test-Path -LiteralPath $configPath

    $windowsSandbox = Get-CodexConfigValue -Section 'windows' -Key 'sandbox'
    $daemonAutoStart = Get-CodexConfigValue -Section 'features' -Key 'daemon_auto_start'

    Write-Log 'codex plan' 'step'
    if (-not $haveConfig) {
        Write-Note 'there is no ~/.codex/config.toml - codex is not set up here, nothing to change'
        return
    }
    if ($haveAccounts -and $windowsSandbox -ne 'elevated') {
        Write-Note "config.toml: windows.sandbox -> elevated (now '$windowsSandbox')"
    }
    if ($daemonAutoStart -ne 'false') {
        Write-Note 'config.toml: features.daemon_auto_start -> false'
    }
    foreach ($agent in @('codex', 'claude')) {
        $skill = Get-CodexSkill -Hc $Hc -Agent $agent
        if ($skill.Exists -and (-not $skill.HcUpToDate -or -not $skill.AppUpToDate -or $skill.MentionsWinHc)) {
            Write-Note "$agent skill: rebuild it from the manuals the installed binaries print"
        }
    }
    if (-not $haveAccounts) {
        Write-Note 'the elevated sandbox is not provisioned - run this in an elevated terminal:'
        Write-Note '  codex sandbox setup --elevated --current-user'
    }
    $daemon = Get-CodexDaemonState
    if ($daemon -and $daemon.status -eq 'running') {
        Write-Note 'a shared app-server daemon is running. Start codex as `codex --no-daemon` (the flag goes before the subcommand).'
        Write-Note '  codex app-server daemon stop   # only when no other session needs it'
    }
    if ($DryRun) { Write-Log 'dry run: the codex side was not changed' 'step'; return }

    if ($haveAccounts -and $windowsSandbox -ne 'elevated') {
        if (Set-CodexConfigValue -Section 'windows' -Key 'sandbox' -Value '"elevated"') {
            Write-Note 'windows.sandbox is now elevated'
        }
    }
    if ($daemonAutoStart -ne 'false') {
        if (Set-CodexConfigValue -Section 'features' -Key 'daemon_auto_start' -Value 'false') {
            Write-Note 'daemon_auto_start is now false'
        }
    }
    foreach ($agent in @('codex', 'claude')) {
        $skill = Get-CodexSkill -Hc $Hc -Agent $agent
        if ($skill.Exists -and (-not $skill.HcUpToDate -or -not $skill.AppUpToDate -or $skill.MentionsWinHc)) {
            if (Update-CodexSkill -Hc $Hc -Agent $agent) { Write-Note "the $agent skill now carries the current manuals" }
        }
    }
}

# ------------------------------------------------------------------------ reporting

function Show-Status {
    param([string] $Hc, [string[]] $GrantSids)

    Write-Log 'herdr-pipe-patch' 'step'
    Write-Note "tool       : $script:ToolRoot"
    Write-Note "session    : $Session"

    if (-not $Hc) {
        Write-Fail 'no herdr-core found on this machine'
        Write-Note "looked in: the app's settings.json, PATH, %LOCALAPPDATA%\Programs\herdr-core, ~\.cargo\bin"
        return $null
    }

    $version = Get-HcVersion $Hc
    $patched = Test-PatchedBinary $Hc
    $status = Get-CoreStatus $Hc

    Write-Log 'install' 'step'
    Write-Note "hc             : $Hc"
    Write-Note "version        : $version"
    Write-Note "patch support  : $(if ($patched) { "yes - the binary honours $script:EnvVar" } else { 'no - this is a stock core' })"
    if ($status) {
        Write-Note "running core   : $($status.version) (pid $($status.pid)), $($status.live) live terminals, $(@($status.holders).Count) holder(s)"
        Write-Note "installed_by   : $(if ($status.installed_by) { $status.installed_by } else { 'a plain install (hc can update it)' })"
    } else {
        Write-Note 'running core   : none'
    }

    $userValue = [Environment]::GetEnvironmentVariable($script:EnvVar, 'User')
    Write-Log 'environment' 'step'
    Write-Note "$($script:EnvVar) (user) : $(if ($userValue) { $userValue } else { 'not set' })"
    if ($GrantSids.Count -gt 0) {
        Write-Note ('to grant       : ' + ($GrantSids -join ', '))
    }

    $pipe = Get-PipePath $Session
    $descriptor = Get-PipeDescriptor $pipe
    Write-Log 'pipe' 'step'
    Write-Note "name   : $pipe"
    if ($descriptor) {
        Write-Note "DACL   : $descriptor"
        $granted = @(Get-DescriptorSids $descriptor)
        Write-Note ('grants : ' + ($granted -join ', '))
        if ($GrantSids.Count -gt 0) {
            $missing = @()
            foreach ($s in $GrantSids) { if (-not $granted.Contains($s)) { $missing += $s } }
            if ($missing.Count -gt 0) {
                Write-Note ('not granted yet : ' + ($missing -join ', '))
            }
        }
    } else {
        Write-Note 'DACL   : unreadable (no core listening on that pipe?)'
    }

    return [pscustomobject]@{
        Hc         = $Hc
        Version    = $version
        Patched    = $patched
        Status     = $status
        Pipe       = $pipe
        Descriptor = $descriptor
        Sids       = $GrantSids
        UserValue  = $userValue
    }
}

# ---------------------------------------------------------------------------- main

Set-CoreEnvironment -ForSession $Session

if ($Command -eq 'build') {
    # Building comes before the core lookup on purpose: a build makes a core,
    # so it must work on a machine that has none - the CI runner, for one.
    if (-not $Version) { Stop-Tool 'build needs -Version (for example -Version 0.1.20).' }
    $buildSids = @(Resolve-TargetSids)
    if ($buildSids.Count -eq 0) { $buildSids = @('S-1-1-0') }
    Build-Payload -Version $Version -GrantSids $buildSids | Out-Null
    Write-Log "payload for $Version is ready" 'step'
    exit 0
}

$hc = $null
try {
    $hc = Get-HcPath $HcPath
} catch {
    Write-Fail $_.Exception.Message
    exit 1
}

$grant = @(Resolve-TargetSids)
# Two different situations look the same from here: the pattern matched no
# account, or the sandbox accounts do not exist on this machine at all. They
# need different advice, so they are told apart. `apply` says its own thing.
if ($grant.Count -eq 0 -and $Command -ne 'status' -and $Command -ne 'apply') {
    $sandboxAccounts = @(Get-CodexSandboxAccounts)
    if ($sandboxAccounts.Count -eq 0) {
        Write-Warn 'the accounts the elevated sandbox runs as do not exist on this machine yet; run this in an elevated terminal:'
        Write-Warn '  codex sandbox setup --elevated --current-user'
    } else {
        Write-Warn "no account on this machine matches what was asked for. Give -Account or -Sids."
    }
}

switch ($Command) {

    'status' {
        $s = Show-Status -Hc $hc -GrantSids $grant
        if (-not $s) { exit 1 }
        $codex = Show-Codex -Hc $hc -GrantSids $grant
        Write-Log 'verdict' 'step'
        if (-not $s.Patched) {
            Write-Note 'the installed core has no support for the variable: run apply.'
        } elseif ($grant.Count -gt 0) {
            $granted = @(Get-DescriptorSids $s.Descriptor)
            $missing = @()
            foreach ($x in $grant) { if (-not $granted.Contains($x)) { $missing += $x } }
            if ($missing.Count -gt 0) {
                Write-Note ('the core is patched but the running one has no grants for: ' + ($missing -join ', ') + ' - run apply.')
            } else {
                Write-Note 'the core is patched and the principals are already granted.'
            }
        } else {
            Write-Note 'the core is patched. Nothing to do.'
        }
        foreach ($p in $codex.Problems) { Write-Note ('codex: ' + $p) }
        exit 0
    }

    'apply' {
        if (-not $hc) { Stop-Tool 'no herdr-core found on this machine.' }
        # No accounts to grant is not a dead end: the patched core does not need
        # them. The core goes in, and the person is told to provision the
        # sandbox and run apply again for the grants.
        $noGrants = ($grant.Count -eq 0)
        if ($noGrants) {
            Write-Warn 'there is nothing to grant: no account on this machine matches what was asked for.'
            Write-Warn 'the patched core goes in anyway - it does not need the accounts.'
            Write-Warn 'if the elevated sandbox is not set up yet, run this in an elevated terminal:'
            Write-Warn '  codex sandbox setup --elevated --current-user'
            Write-Warn 'and run apply again afterwards, to grant the sandbox accounts.'
        }

        # The SIDs the installed core will actually grant. This is worked out
        # before the candidate is checked, so the candidate is proved against
        # the very SIDs the new core will carry.
        $grantSids = @($grant)
        $grantValue = ($grantSids -join ';')
        if ($noGrants) {
            $existing = [Environment]::GetEnvironmentVariable($script:EnvVar, 'User')
            if ($existing) {
                # The variable keeps what it had: an empty grant list must not
                # clear the grants that are already in place.
                $grantValue = $existing
                $grantSids = @($existing -split ';' | Where-Object { $_ })
                Write-Note "nothing was named to grant; the grants already in place are kept: $existing"
            } else {
                $grantValue = ''
                Write-Note 'there is no variable set either: the core will grant SYSTEM and its owner, and nobody else'
            }
        }

        $s = Show-Status -Hc $hc -GrantSids $grant
        $installedVersion = ($s.Version -replace '^hc ', '')

        Write-Log 'plan' 'step'
        if (-not $s.Patched) {
            Write-Note "install a patched core for $installedVersion"
        } else {
            Write-Note 'the core is already patched; only the variable and a restart are needed'
        }
        if (-not $noGrants) { Write-Note "grant: $($grant -join ', ')" }
        Write-Note "restart the core so it reads $script:EnvVar"

        if ($DryRun) {
            Repair-Codex -Hc $hc -GrantSids $grant -DryRun
            Write-Log 'dry run: nothing was changed' 'step'
            exit 0
        }

        if (-not $s.Patched) {
            $candidate = Get-PatchedCore -WantedVersion $installedVersion -GrantSids $grantSids -AllowBuild

            Write-Step 'checking the candidate grants the SIDs before installing it'
            $check = Test-CandidateBinary -Candidate $candidate -GrantSids $grantSids
            if (-not $check.Ok) {
                Stop-Tool "the candidate does not grant $($check.Missing -join ', '). It was not installed."
            }
            Write-Note 'the candidate grants the SIDs when run as an isolated core'

            Write-Step 'backing up the installed core'
            $installDir = Split-Path -Parent $Hc
            $backup = Join-Path $installDir "herdr-core.exe.stock-$installedVersion.bak"
            Copy-Item -LiteralPath $Hc -Destination $backup -Force
            Write-Note "saved the stock core as $backup"

            Write-Step 'installing the patched core'
            Install-Core -Hc $hc -Candidate $candidate | Out-Null
        }

        Write-Step "setting $script:EnvVar"
        if ($noGrants) {
            Write-Note "left as it is: $(if ($grantValue) { $grantValue } else { 'not set' })"
        } else {
            Set-UserEnvironment -Name $script:EnvVar -Value $grantValue
            Set-Item -Path "Env:$script:EnvVar" -Value $grantValue
            Write-Note "user environment: $grantValue"
        }

        Write-Step 'restarting the core'
        $restart = Restart-Core -Hc $hc -Environment @{ $script:EnvVar = $grantValue } -ForSession $Session -Fresh
        if (-not $restart.Ok) { Stop-Tool "the core did not come back: $($restart.Result.Text)" }
        Write-Note "restarted with: $($restart.How)"
        Start-Sleep -Milliseconds 1200

        Write-Step 'the codex side'
        Repair-Codex -Hc $hc -GrantSids $grant

        Write-Step 'verifying'
        $after = Show-Status -Hc $hc -GrantSids $grant
        $granted = @(Get-DescriptorSids $after.Descriptor)
        $missing = @()
        foreach ($x in $grant) { if (-not $granted.Contains($x)) { $missing += $x } }
        if ($missing.Count -gt 0) { Stop-Tool "the pipe still does not grant: $($missing -join ', ')" }
        if ($Probe) { Invoke-Probe -Hc $hc }
        if ($noGrants) {
            Write-Log 'done: the core is patched; there are no accounts to grant yet' 'step'
        } else {
            Write-Log 'done: the core is patched and the principals are granted' 'step'
        }
        exit 0
    }

    'unpatch' {
        if (-not $hc) { Stop-Tool 'no herdr-core found on this machine.' }
        $s = Show-Status -Hc $hc -GrantSids $grant
        $installedVersion = ($s.Version -replace '^hc ', '')
        $installDir = Split-Path -Parent $Hc

        Write-Log 'plan' 'step'
        Write-Note 'put the stock core back'
        Write-Note "remove $script:EnvVar from the user environment"
        Write-Note 'restart the core so it stops granting'

        if ($DryRun) { Write-Log 'dry run: nothing was changed' 'step'; exit 0 }

        Write-Step 'restoring the stock core'
        $backup = Join-Path $installDir "herdr-core.exe.stock-$installedVersion.bak"
        $stock = $null
        if (Test-Path -LiteralPath $backup) {
            Write-Note "using the saved stock core $backup"
            $stock = $backup
        } else {
            $base = if ($ReleasesUrl) { $ReleasesUrl } elseif ($env:HERDR_RELEASES_URL) { $env:HERDR_RELEASES_URL } else { 'https://releases.herdr.dev' }
            $scratch = Join-Path $env:TEMP ("hpp-stock-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Force -Path $scratch | Out-Null
            $stock = Get-StockCore -WantedVersion $installedVersion -Base $base.TrimEnd('/') -Scratch $scratch
        }
        Install-Core -Hc $hc -Candidate $stock | Out-Null

        Write-Step "removing $script:EnvVar from the user environment"
        Set-UserEnvironment -Name $script:EnvVar -Value $null
        Remove-Item -Path "Env:$script:EnvVar" -ErrorAction SilentlyContinue

        Write-Step 'restarting the core'
        $restart = Restart-Core -Hc $hc -Environment @{} -ForSession $Session
        if (-not $restart.Ok) { Stop-Tool "the core did not come back: $($restart.Result.Text)" }
        Start-Sleep -Milliseconds 1200

        Write-Step 'verifying'
        $after = Show-Status -Hc $hc -GrantSids @()
        if ($after.Patched) { Stop-Tool 'the installed core still carries the patch support.' }
        $granted = @(Get-DescriptorSids $after.Descriptor)
        if ($grant.Count -gt 0) {
            $still = @()
            foreach ($x in $grant) { if ($granted.Contains($x)) { $still += $x } }
            if ($still.Count -gt 0) { Stop-Tool "the pipe still grants: $($still -join ', ')" }
        }
        Write-Log 'done: the stock core is back and the grants are gone' 'step'
        exit 0
    }

    'verify' {
        if (-not $hc) { Stop-Tool 'no herdr-core found on this machine.' }
        $s = Show-Status -Hc $hc -GrantSids $grant
        $codex = Show-Codex -Hc $hc -GrantSids $grant
        $problems = @()
        if (-not $s.Patched) { $problems += 'the installed core has no patch support' }
        if ($grant.Count -gt 0) {
            $granted = @(Get-DescriptorSids $s.Descriptor)
            foreach ($x in $grant) { if (-not $granted.Contains($x)) { $problems += "the pipe does not grant $x" } }
        }
        if (-not $s.Status) { $problems += 'no core is running' }
        foreach ($p in $codex.Problems) { $problems += "codex: $p" }
        if ($problems.Count -gt 0) {
            foreach ($p in $problems) { Write-Fail $p }
            exit 1
        }
        # The probe runs before the verdict: a verdict that says "verified"
        # while the proof is still to come would be printed before a probe
        # that might fail.
        if ($Probe) { Invoke-Probe -Hc $hc }
        Write-Log 'verified' 'step'
        exit 0
    }
}

exit 0
