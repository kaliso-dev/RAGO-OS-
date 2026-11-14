# SPDX-License-Identifier: GPL-2.0
<#
.SYNOPSIS
    Rapport de mesure du micro-Windows Rago (module M5) : RAM au repos,
    processus, services, sécurité, taille sur le disque.

.DESCRIPTION
    Sert le critère de test de M5 : RAM au repos ~300-500 Mo, pas
    d'explorer.exe ni de SearchIndexer, Secure Boot / TPM / VBS / HVCI / IOMMU,
    et la taille RÉELLE de l'installation (mesurée, jamais estimée).

    Attend -SettleSeconds secondes (système au repos), mesure, puis écrit :
      RAGO-COMM\reports\m5-engine.json            (lu par Linux : setup_windows_security.sh status)
      C:\ProgramData\Rago\reports\m5-engine-<date>.json
    Aucune valeur n'est inventée : ce qui n'a pas pu être lu vaut null, avec
    l'erreur dans « errors ».

.PARAMETER SettleSeconds
    Attente avant la mesure de la RAM (défaut 60 s).
.PARAMETER WaitForShell
    Attend d'abord (5 min au plus) que le shell Rago du joueur tourne : la
    mesure « au repos » se fait session ouverte, pas pendant l'ouverture.
#>
[CmdletBinding()]
param([int]$SettleSeconds = 60, [switch]$WaitForShell)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RagoComm.psm1') -Force
Set-RagoLogName 'report'

$errors = @()
$t0 = Get-Date
$shellSeen = $null
$shellStart = $null
if ($WaitForShell) {
    $shellSeen = $false
    $deadline = (Get-Date).AddMinutes(5)
    while (-not $shellSeen -and (Get-Date) -lt $deadline) {
        $p = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -like '*rago-shell.ps1*' })
        if ($p.Count -gt 0) { $shellSeen = $true; $shellStart = $p[0].CreationDate } else { Start-Sleep -Seconds 2 }
    }
    if (-not $shellSeen) { $errors += 'shell Rago introuvable après 5 min : mesure faite quand même' }
}
if ($SettleSeconds -gt 0) { Start-Sleep -Seconds $SettleSeconds }

function Get-Mib { param([double]$Bytes); return [math]::Round($Bytes / 1048576, 1) }

# --- RAM (classes WMI : indépendantes de la langue, contrairement à Get-Counter) ---------------
$ram = [ordered]@{ total_mib = $null; in_use_mib = $null; available_mib = $null; committed_mib = $null; standby_mib = $null }
try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $ram.total_mib = [math]::Round($os.TotalVisibleMemorySize / 1024, 1)
    $mem = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Memory
    $ram.available_mib = [double]$mem.AvailableMBytes
    $ram.in_use_mib = [math]::Round($ram.total_mib - $ram.available_mib, 1)
    $ram.committed_mib = Get-Mib ([double]$mem.CommittedBytes)
    $sb = 0
    foreach ($n in 'StandbyCacheCoreBytes', 'StandbyCacheNormalPriorityBytes', 'StandbyCacheReserveBytes') {
        if ($mem.PSObject.Properties.Name -contains $n) { $sb += [double]$mem.$n }
    }
    $ram.standby_mib = Get-Mib $sb
} catch { $errors += ('RAM : ' + $_.Exception.Message) }

# --- processus et services ---------------------------------------------------------------
$procs = @()
try {
    $procs = @(Get-Process | Sort-Object -Property WorkingSet64 -Descending |
        ForEach-Object { [ordered]@{ name = $_.ProcessName; pid = $_.Id; working_set_mib = (Get-Mib $_.WorkingSet64) } })
} catch { $errors += ('processus : ' + $_.Exception.Message) }
$names = @($procs | ForEach-Object { $_.name })
$services = @()
try { $services = @(Get-Service | Where-Object { $_.Status -eq 'Running' } | Sort-Object Name | ForEach-Object { $_.Name }) }
catch { $errors += ('services : ' + $_.Exception.Message) }

# --- disque : C:, sans pagefile / hiberfil / swapfile (comptés à part) ------------------------
$disk = [ordered]@{ c_size_mib = $null; c_used_mib = $null; pagefile_mib = 0; hiberfil_mib = 0; swapfile_mib = 0; c_used_without_page_hiber_swap_mib = $null; compact_os = $null; compact_os_query = $null }
try {
    $c = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID = '{0}'" -f $env:SystemDrive)
    $disk.c_size_mib = Get-Mib ([double]$c.Size)
    $used = [double]$c.Size - [double]$c.FreeSpace
    $disk.c_used_mib = Get-Mib $used
    $extra = 0
    foreach ($f in @(@('pagefile.sys', 'pagefile_mib'), @('hiberfil.sys', 'hiberfil_mib'), @('swapfile.sys', 'swapfile_mib'))) {
        $p = Join-Path ($env:SystemDrive + '\') $f[0]
        $item = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
        if ($null -ne $item) { $disk[$f[1]] = Get-Mib $item.Length; $extra += $item.Length }
    }
    $disk.c_used_without_page_hiber_swap_mib = Get-Mib ($used - $extra)
} catch { $errors += ('disque : ' + $_.Exception.Message) }
try { $disk.compact_os = Test-RagoCompactOS } catch { $errors += ('CompactOS : ' + $_.Exception.Message) }
try { $disk.compact_os_query = ((& "$env:SystemRoot\System32\compact.exe" /CompactOS:query) | Out-String).Trim() }
catch { $errors += ('compact : ' + $_.Exception.Message) }

# --- démarrage ----------------------------------------------------------------------------
$boot = [ordered]@{ boot_id = $null; seconds_kernel_to_report_start = $null; seconds_kernel_to_shell = $null; boot_time_ms_event = $null }
try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $boot.boot_id = $os.LastBootUpTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $boot.seconds_kernel_to_report_start = [math]::Round(($t0 - $os.LastBootUpTime).TotalSeconds, 1)
    if ($null -ne $shellStart) { $boot.seconds_kernel_to_shell = [math]::Round(($shellStart - $os.LastBootUpTime).TotalSeconds, 1) }
} catch { $errors += ('démarrage : ' + $_.Exception.Message) }
try {
    # Événement 100 de Diagnostics-Performance : durée du démarrage mesurée par Windows.
    $e = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents 1 -ErrorAction Stop
    $x = [xml]$e.ToXml()
    $bt = $x.Event.EventData.Data | Where-Object { $_.Name -eq 'BootTime' } | Select-Object -First 1
    if ($null -ne $bt) { $boot.boot_time_ms_event = [int]$bt.'#text' }
} catch { $boot.boot_time_ms_event = $null }

# --- sécurité : ce qu'a mesuré rago-security.ps1 à ce démarrage ---------------------------------
$sec = $null
try { $sec = Read-RagoJson (Join-Path (Get-RagoDataDir) 'security-status.json') } catch { $errors += ('security-status : ' + $_.Exception.Message) }

$info = $null
try { $info = Read-RagoJson (Join-Path (Get-RagoRootDir) 'micro-engine.json') } catch { $info = $null }

$report = [ordered]@{
    schema = 1
    kind = 'rago-m5-engine-report'
    written_at = (Get-RagoUtcNow)
    settle_seconds = $SettleSeconds
    shell_seen_before_measure = $shellSeen
    ram = $ram
    explorer_running = ($names -contains 'explorer')
    search_indexer_running = ($names -contains 'SearchIndexer')
    process_count = $procs.Count
    processes = $procs
    services_running_count = $services.Count
    services_running = $services
    disk = $disk
    boot = $boot
    security = $sec
    build = $info
    errors = $errors
}

$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
Write-RagoJson -Path (Join-Path (Get-RagoDataDir) ("reports\m5-engine-{0}.json" -f $stamp)) -InputObject $report
$root = Get-RagoCommRoot
if ($null -ne $root) {
    try { Write-RagoJson -Path (Join-Path $root 'reports\m5-engine.json') -InputObject $report }
    catch { Write-RagoLog ('rapport dans RAGO-COMM impossible : ' + $_.Exception.Message) 'ERROR' }
}
Write-RagoLog ('rapport : RAM utilisée {0} Mio, explorer {1}, C: {2} Mio (sans pagefile/hiberfil)' -f $ram.in_use_mib, $report.explorer_running, $disk.c_used_without_page_hiber_swap_mib)
'RAM utilisée au repos : {0} Mio sur {1} Mio' -f $ram.in_use_mib, $ram.total_mib
'explorer.exe : {0} ; SearchIndexer : {1}' -f $report.explorer_running, $report.search_indexer_running
'C: occupé : {0} Mio (dont pagefile {1}, hiberfil {2}, swapfile {3}) ; sans eux : {4} Mio' -f $disk.c_used_mib, $disk.pagefile_mib, $disk.hiberfil_mib, $disk.swapfile_mib, $disk.c_used_without_page_hiber_swap_mib
if ($null -ne $sec) { 'Sécurité : demandé {0}, effectif {1}' -f $sec.requested, $sec.effective }
exit 0
