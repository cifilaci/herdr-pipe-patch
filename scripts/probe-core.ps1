<#
.SYNOPSIS
  Checks that a herdr-core binary really grants the given SIDs on its pipes.

.DESCRIPTION
  A patched core carries the string HERDR_PIPE_EXTRA_SIDS, but the string is not
  the feature: the feature is the allow-ACE the core puts in every pipe's
  descriptor. This script starts the binary as an isolated core (its own
  session, its own pipe), reads that pipe's descriptor back, and reports whether
  the SIDs are in it. It changes nothing outside its own session directory, which
  it removes afterwards.

.EXAMPLE
  .\scripts\probe-core.ps1 -Core .\herdr-core.exe -Sids 'S-1-1-0'
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Core,

    # The SIDs to look for, separated by , or ;
    [string] $Sids = 'S-1-1-0'
)

$ErrorActionPreference = 'Stop'

if (-not ('HerdrPipePatchProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class HerdrPipePatchProbe {
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern int GetNamedSecurityInfoW(string name, int objType, uint info,
        out IntPtr owner, out IntPtr group, out IntPtr dacl, out IntPtr sacl, out IntPtr sd);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool ConvertSecurityDescriptorToStringSecurityDescriptorW(
        IntPtr sd, uint flags, uint info, out IntPtr str, out uint len);

    [DllImport("kernel32.dll")]
    static extern IntPtr LocalFree(IntPtr p);

    public static string ReadDescriptor(string path) {
        IntPtr owner, group, dacl, sacl, sd;
        if (GetNamedSecurityInfoW(path, 1, 1 | 2 | 4, out owner, out group, out dacl, out sacl, out sd) != 0) return null;
        IntPtr str; uint len;
        if (!ConvertSecurityDescriptorToStringSecurityDescriptorW(sd, 1, 1 | 2 | 4, out str, out len)) {
            LocalFree(sd); return null;
        }
        string r = Marshal.PtrToStringUni(str);
        LocalFree(str); LocalFree(sd);
        return r;
    }
}
'@
}

function Invoke-Native {
    param([string] $File, [string[]] $Arguments)
    $previous = $ErrorActionPreference
    $previousEncoding = [Console]::OutputEncoding
    $ErrorActionPreference = 'Continue'
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    try {
        $text = (& $File @Arguments 2>&1 | Out-String).Trim()
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
        [Console]::OutputEncoding = $previousEncoding
    }
    return [pscustomobject]@{ ExitCode = $code; Text = $text }
}

if (-not (Test-Path -LiteralPath $Core -PathType Leaf)) {
    Write-Host "x there is no file at $Core" -ForegroundColor Red
    exit 1
}

# SDDL writes the well-known principals as short names: Everyone comes back as
# "WD" and SYSTEM as "SY". A caller asks with SIDs, so they are translated.
$wellKnown = @{
    'WD' = 'S-1-1-0'; 'AN' = 'S-1-5-7'; 'AU' = 'S-1-5-11'; 'IU' = 'S-1-5-4'
    'SY' = 'S-1-5-18'; 'LS' = 'S-1-5-19'; 'NS' = 'S-1-5-20'
    'BA' = 'S-1-5-32-544'; 'BU' = 'S-1-5-32-545'; 'RC' = 'S-1-5-32-555'
}

$version = Invoke-Native -File $Core -Arguments @('--version')
if ($version.ExitCode -ne 0 -or -not $version.Text) {
    Write-Host "x $Core is not a core that runs here (its --version does not answer)" -ForegroundColor Red
    exit 1
}
Write-Host "core      : $Core ($($version.Text))"

$wanted = @($Sids -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($wanted.Count -eq 0) { $wanted = @('S-1-1-0') }

$session = 'hpp-probe-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$savedSession = $env:HC_SESSION
$savedSids = $env:HERDR_PIPE_EXTRA_SIDS
try {
    $env:HC_SESSION = $session
    $env:HERDR_PIPE_EXTRA_SIDS = ($wanted -join ';')
    Remove-Item Env:HC_TERMINAL_ID -ErrorAction SilentlyContinue
    Remove-Item Env:HC_SOCKET -ErrorAction SilentlyContinue

    Invoke-Native -File $Core -Arguments @('server', 'start', '--json') | Out-Null

    # The serving core writes its pipe path into core.lock; fall back to the
    # name it would use.
    $lock = Join-Path (Join-Path $env:LOCALAPPDATA 'herdr-core') (Join-Path $session 'core.lock')
    $pipe = $null
    if (Test-Path -LiteralPath $lock) {
        try {
            $raw = [IO.File]::ReadAllText($lock).Trim()
            if ($raw -and $raw.StartsWith('\\.\pipe\')) { $pipe = $raw }
        } catch { }
    }
    if (-not $pipe) {
        $user = ($env:USERNAME -replace '[^A-Za-z0-9]', '')
        $pipe = "\\.\pipe\herdr-core-$user-$session.sock"
    }

    # The core needs a moment to create its pipe; a slow machine needs more
    # than a fixed sleep, so the descriptor is read until it answers.
    $descriptor = $null
    for ($i = 0; $i -lt 60 -and -not $descriptor; $i++) {
        $descriptor = [HerdrPipePatchProbe]::ReadDescriptor($pipe)
        if (-not $descriptor) { Start-Sleep -Milliseconds 500 }
    }

    Invoke-Native -File $Core -Arguments @('server', 'stop', '--json') | Out-Null

    Write-Host "pipe      : $pipe"
    Write-Host "descriptor: $descriptor"
    if (-not $descriptor) {
        Write-Host 'x the pipe descriptor could not be read' -ForegroundColor Red
        exit 1
    }

    $missing = @()
    foreach ($sid in $wanted) {
        $granted = $false
        foreach ($m in [regex]::Matches($descriptor, '\([A-Z]+;;[A-Z]+;;;([^)]*)\)')) {
            $found = $m.Groups[1].Value
            if ($wellKnown.ContainsKey($found)) { $found = $wellKnown[$found] }
            if ($found -eq $sid) { $granted = $true; break }
        }
        if (-not $granted) { $missing += $sid }
    }
    if ($missing.Count -gt 0) {
        Write-Host "x it does not grant: $($missing -join ', ')" -ForegroundColor Red
        exit 1
    }
    Write-Host "ok it grants: $($wanted -join ', ')" -ForegroundColor Green
    exit 0
} finally {
    if ($null -eq $savedSession) { Remove-Item Env:HC_SESSION -ErrorAction SilentlyContinue }
    else { $env:HC_SESSION = $savedSession }
    if ($null -eq $savedSids) { Remove-Item Env:HERDR_PIPE_EXTRA_SIDS -ErrorAction SilentlyContinue }
    else { $env:HERDR_PIPE_EXTRA_SIDS = $savedSids }
    Start-Sleep -Milliseconds 400
    Remove-Item -LiteralPath (Join-Path (Join-Path $env:LOCALAPPDATA 'herdr-core') $session) -Recurse -Force -ErrorAction SilentlyContinue
}
