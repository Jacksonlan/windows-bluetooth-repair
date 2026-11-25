<#
.SYNOPSIS
    Read-only diagnostic report for Windows Bluetooth adapter failures.

.DESCRIPTION
    Collects everything needed to decide WHY a Bluetooth radio is not available:
    service state, adapter problem codes, driver version, recent Bluetooth driver
    errors from the event log, USB power-management state, fast-startup state,
    and whether the self-healing guard task is installed.

    No changes are made to the system. Runs without administrator rights.

.PARAMETER OutFile
    Optional path for a text copy of the report.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File diagnose-bluetooth.ps1
#>
[CmdletBinding()]
param([string]$OutFile)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$lines = New-Object System.Collections.Generic.List[string]
function Say([string]$s) { $script:lines.Add($s); Write-Host $s }

Say "=== Windows Bluetooth diagnostic ==================================="
Say ("Time : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
$os = Get-CimInstance Win32_OperatingSystem
Say ("OS   : {0} (build {1})" -f $os.Caption, $os.BuildNumber)

# ---------------------------------------------------------------- services
Say ""
Say "-- [1] Bluetooth services --"
foreach ($n in 'bthserv', 'BTAGService') {
    $s = Get-Service -Name $n
    if ($s) { Say ("  {0,-12} {1,-9} StartType={2}" -f $s.Name, $s.Status, $s.StartType) }
    else { Say ("  {0,-12} NOT FOUND" -f $n) }
}
Get-Service | Where-Object { $_.Name -like 'BluetoothUserService*' } | ForEach-Object {
    Say ("  {0,-32} {1,-9} StartType={2}" -f $_.Name, $_.Status, $_.StartType)
}

# ---------------------------------------------------------------- adapters
Say ""
Say "-- [2] Bluetooth devices currently present --"
$present = Get-PnpDevice -Class Bluetooth -PresentOnly
if (-not $present) {
    Say "  NONE PRESENT"
    Say "  => radio switched off, adapter disabled, or hardware not enumerated."
} else {
    # the radio itself is the USB-backed (or sole) node; everything else are children
    $radioList = @($present | Where-Object { $_.InstanceId -like 'USB\*' })
    if ($radioList.Count -eq 0) { $radioList = @($present | Select-Object -First 1) }
    $problems = @($present | Where-Object { $_.Status -ne 'OK' })

    foreach ($r in $radioList) {
        Say ("  RADIO    {0}  [{1}/{2}]" -f $r.FriendlyName, $r.Status, $r.Problem)
    }
    Say ("  total nodes present: {0}, of which failing: {1}" -f $present.Count, $problems.Count)

    foreach ($d in $problems) {
        Say ""
        Say ("  PROBLEM  {0}" -f $d.FriendlyName)
        Say ("           Status      : {0}" -f $d.Status)
        Say ("           Problem     : {0}" -f $d.Problem)
        Say ("           Description : {0}" -f $d.ProblemDescription)
        Say ("           InstanceId  : {0}" -f $d.InstanceId)
        $dv = Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName DEVPKEY_Device_DriverVersion
        $dd = Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName DEVPKEY_Device_DriverDate
        $dp = Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName DEVPKEY_Device_DriverProvider
        Say ("           Driver      : {0} {1} ({2:yyyy-MM-dd})" -f $dp.Data, $dv.Data, $dd.Data)
    }
    if ($problems.Count -eq 0) { Say "  no failing Bluetooth node - radio and children all OK" }
}

$phantom = @(Get-PnpDevice -Class Bluetooth | Where-Object { $_.Problem -eq 'CM_PROB_PHANTOM' })
Say ""
Say ("-- [3] Stale/phantom Bluetooth nodes: {0} --" -f $phantom.Count)
Say "  (Normal when the radio is down. They disappear once the radio starts.)"

# ---------------------------------------------------------------- event log
Say ""
Say "-- [4] Bluetooth driver errors, last 7 days --"
$ev = Get-WinEvent -FilterHashtable @{
    LogName   = 'System'
    StartTime = (Get-Date).AddDays(-7)
} | Where-Object { $_.ProviderName -match '^BTHUSB$|^BTHPORT$|^BthServ$|^BthA2dp$|^BTHENUM$' }
$bad = @($ev | Where-Object { $_.Level -in 1, 2, 3 })   # 1=Critical 2=Error 3=Warning (locale-independent)
if ($bad.Count -eq 0) {
    Say "  none"
} else {
    $bad | Select-Object -First 12 | ForEach-Object {
        $msg = ($_.Message -replace "`r`n", ' ')
        if ($msg.Length -gt 110) { $msg = $msg.Substring(0, 110) + '...' }
        Say ("  {0:MM-dd HH:mm}  id={1,-3} {2,-10} {3}" -f $_.TimeCreated, $_.Id, $_.LevelDisplayName, $msg)
    }
    Say "  NOTE: BTHUSB id=7 means a hardware-level error reported by the radio."
}

# ---------------------------------------------------------------- power mgmt
Say ""
Say "-- [5] USB power management on the Bluetooth chain --"
$radio = $present | Where-Object { $_.InstanceId -like 'USB\*' } | Select-Object -First 1
if ($radio) {
    $chain = New-Object System.Collections.Generic.List[string]
    $cur = $radio.InstanceId
    for ($i = 0; $i -lt 5 -and $cur; $i++) {
        if (-not $chain.Contains($cur)) { $chain.Add($cur) }
        $p = (Get-PnpDeviceProperty -InstanceId $cur -KeyName DEVPKEY_Device_Parent).Data
        if ($p -eq $cur) { break }
        $cur = $p
    }
    $pm = Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable
    foreach ($inst in $chain) {
        $row = $pm | Where-Object { $_.InstanceName -eq "${inst}_0" }
        if ($row) {
            $state = if ($row.Enable) { 'ON  (device MAY be powered down to save energy - risk)' } else { 'OFF (good)' }
            Say ("  {0}`n           allow-sleep-to-save-power = {1}" -f $inst, $state)
        } else {
            Say ("  {0}`n           (no power-management entry)" -f $inst)
        }
    }
} else {
    Say "  no USB-backed Bluetooth radio found, skipped"
}

Say ""
Say "-- [6] Fast startup (hiberboot) --"
$hb = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power").HiberbootEnabled
Say ("  HiberbootEnabled = {0}  {1}" -f $hb, $(if ($hb -eq 1) { '(ON - a known contributor to device-init failures on boot)' } else { '(OFF - good)' }))

Say ""
Say "-- [7] Self-healing guard task --"
# The install marker lives in a Users-readable folder. A SYSTEM task itself is
# NOT reliably visible from a non-admin session (the Tasks folder denies access),
# so never report "not installed" just because the API returns nothing.
$marker = 'C:\ProgramData\BTGuard\installed.json'
$known = $false
if (Test-Path $marker) {
    $m = Get-Content $marker -Raw | ConvertFrom-Json
    Say ("  marker  : task='{0}'  pattern='{1}'  delay={2}s  installed={3}" -f $m.TaskName, $m.DevicePattern, $m.DelaySeconds, $m.InstalledAt)
    $known = $true
}
$t = Get-ScheduledTask -TaskName 'BTGuardAutoRepair'
if ($t) {
    Say ("  api     : state={0}  runAs={1}  level={2}  delay={3}" -f $t.State, $t.Principal.UserId, $t.Principal.RunLevel, $t.Triggers[0].Delay)
    $known = $true
}
if (-not $known) {
    $adm = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($adm) { Say "  NOT INSTALLED" }
    else {
        Say "  UNKNOWN - no marker and the task API returned nothing."
        Say "  A SYSTEM-level task can be hidden from a non-admin session; re-run elevated to confirm."
    }
}
$gl = 'C:\ProgramData\BTGuard\bt-guard.log'
if (Test-Path $gl) {
    Say "  guard log (last 6 lines, empty means it has not run yet):"
    Get-Content $gl -Tail 6 | ForEach-Object { Say ("    " + $_) }
}

Say ""
Say "=== end ==========================================================="

if ($OutFile) {
    $lines | Out-File -FilePath $OutFile -Encoding utf8
    Write-Host ""
    Write-Host "Report written to: $OutFile"
}
