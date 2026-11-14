# SPDX-License-Identifier: GPL-2.0
<#
.SYNOPSIS
    Profil de sécurité du micro-Windows Rago (module M5) : compat_max ou perf.

.DESCRIPTION
    Côté Linux, `rago-profiled prepare-switch --id <jeu>` (M14) appelle le hook
    windows-security (M5), qui écrit le profil du jeu dans la partition
    d'échange RAGO-COMM : security\profile.json. Ce script, lancé à CHAQUE
    démarrage par la tâche \Rago\Boot (compte SYSTEM, via rago-boot.ps1), le lit
    et l'applique :

      compat_max  hyperviseur lancé (hypervisorlaunchtype Auto) : VBS + HVCI
                  tournent (exigés par Vanguard On-Demand, Ricochet…).
      perf        hyperviseur coupé (hypervisorlaunchtype Off) : VBS / HVCI ne
                  tournent pas (quelques FPS de plus, pour les jeux dont
                  l'anti-triche ne les demande pas : EAC, BattlEye…).

    Dans les DEUX profils : Secure Boot, TPM, IOMMU (réglages du firmware,
    jamais touchés), Defender, pare-feu et liste de blocage des pilotes
    vulnérables restent actifs. La configuration VBS / HVCI du registre reste
    toujours celle de compat_max (posée par compile_micro_engine.ps1, sans
    verrou UEFI) : seul l'hyperviseur change. Rien n'est caché à l'anti-triche :
    l'état réel est mesuré (Win32_DeviceGuard) et renvoyé à Linux.

    Un changement de profil ne prend effet qu'au démarrage suivant : si le
    profil demandé n'est pas celui en place, le script le pose, demande au
    firmware de redémarrer une fois sur Windows (BootNext = Windows Boot
    Manager, entrée à usage unique) et redémarre. Deux switchs de suite avec le
    même profil ne coûtent donc rien ; un changement de profil coûte un
    démarrage de Windows de plus. Garde-fou : jamais deux redémarrages de suite
    pour le même profil.

    Sans demande lisible dans RAGO-COMM : compat_max (comme le profil sûr par
    défaut de rago-profiled).

    Résultat : RAGO-COMM\security\status.json (lu par Linux au retour) et
    C:\ProgramData\Rago\security-status.json (attendu par le shell).

.PARAMETER Apply
    Mode tâche de démarrage (SYSTEM) : lit la demande, applique, redémarre si besoin.
.PARAMETER Set
    Pose un profil à la main (maintenance), sans lire RAGO-COMM.
.PARAMETER Status
    Affiche l'état (JSON) sans rien changer.
.PARAMETER NoReboot
    Ne redémarre jamais (premier démarrage, maintenance) : le profil prendra effet au prochain démarrage.
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [ValidateSet('compat_max', 'perf')][string]$Set,
    [switch]$Status,
    [switch]$NoReboot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RagoComm.psm1') -Force
Set-RagoLogName 'security'

$DataDir = Get-RagoDataDir
$StatePath = Join-Path $DataDir 'security-state.json'
$LocalStatusPath = Join-Path $DataDir 'security-status.json'
$LoopGuardMinutes = 15

# Réglage de l'hyperviseur (BCD de l'entrée Windows en cours) pour chaque profil.
$HypervisorLaunchType = @{ compat_max = 'Auto'; perf = 'Off' }

# Base de sécurité du registre, la même pour les deux profils (= compat_max).
$DG = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard'
$Baseline = @(
    @{ Path = $DG; Name = 'EnableVirtualizationBasedSecurity'; Value = 1 },
    @{ Path = $DG; Name = 'RequirePlatformSecurityFeatures'; Value = 1 },
    @{ Path = $DG; Name = 'Locked'; Value = 0 },
    @{ Path = "$DG\Scenarios\HypervisorEnforcedCodeIntegrity"; Name = 'Enabled'; Value = 1 },
    @{ Path = "$DG\Scenarios\HypervisorEnforcedCodeIntegrity"; Name = 'Locked'; Value = 0 },
    @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config'; Name = 'VulnerableDriverBlocklistEnable'; Value = 1 }
)

function Invoke-Bcdedit {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    # Les identifiants entre accolades sont passés en chaînes : sans guillemets,
    # PowerShell lirait {current} comme un bloc de script.
    $out = & "$env:SystemRoot\System32\bcdedit.exe" @Arguments 2>&1
    $code = $LASTEXITCODE
    Write-RagoLog ('bcdedit {0} -> {1} {2}' -f ($Arguments -join ' '), $code, (($out | Out-String).Trim()))
    return $code
}

function Get-RagoSecurityState {
    $out = [pscustomobject]@{ configured = $null; changed_at = $null; reboot_for = $null; reboot_at = $null }
    try { $s = Read-RagoJson $StatePath } catch { $s = $null }
    if ($null -ne $s) {
        foreach ($k in 'configured', 'changed_at', 'reboot_for', 'reboot_at') {
            if ($s.PSObject.Properties.Name -contains $k) { $out.$k = $s.$k }
        }
    }
    # Une valeur inconnue (fichier abîmé) vaut « rien de posé » : le profil sera reposé.
    if (-not (Test-RagoSecurityValue $out.configured)) { $out.configured = $null }
    return $out
}

function Save-RagoSecurityState { param($State); Write-RagoJson -Path $StatePath -InputObject $State }

# Réaffirme la base du registre ; renvoie la liste des valeurs corrigées.
function Set-RagoBaseline {
    $fixed = @()
    foreach ($b in $Baseline) {
        if (-not (Test-Path -LiteralPath $b.Path)) { New-Item -Path $b.Path -Force | Out-Null }
        $cur = (Get-ItemProperty -LiteralPath $b.Path -Name $b.Name -ErrorAction SilentlyContinue)
        $val = $null
        if ($null -ne $cur) { $val = $cur.($b.Name) }
        if ($val -ne $b.Value) {
            New-ItemProperty -LiteralPath $b.Path -Name $b.Name -PropertyType DWord -Value $b.Value -Force | Out-Null
            $fixed += ('{0}\{1}: {2} -> {3}' -f $b.Path, $b.Name, $val, $b.Value)
        }
    }
    return $fixed
}

function Set-RagoProfile {
    param([Parameter(Mandatory = $true)][string]$Name)
    $type = $HypervisorLaunchType[$Name]
    $code = Invoke-Bcdedit @('/set', '{current}', 'hypervisorlaunchtype', $type)
    if ($code -ne 0) { throw ('bcdedit hypervisorlaunchtype {0} : code {1}' -f $type, $code) }
}

# État RÉEL (pas la configuration) : ce que voit aussi l'anti-triche.
function Get-RagoSecurityRunning {
    $r = [ordered]@{
        vbs = 'inconnu'; hvci_running = $null; credential_guard_running = $null
        kernel_stack_protection = 'inconnu'
        hypervisor_present = $null; hypervisor_support = $null; dma_protection = $null
        secure_boot = $null; tpm_present = $null; tpm_ready = $null; tpm_version = $null
        vulnerable_driver_blocklist = $null; errors = @()
    }
    try {
        $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard
        switch ([int]$dg.VirtualizationBasedSecurityStatus) {
            0 { $r.vbs = 'off' }
            1 { $r.vbs = 'enabled_not_running' }
            2 { $r.vbs = 'running' }
        }
        $running = @($dg.SecurityServicesRunning)
        $avail = @($dg.AvailableSecurityProperties)
        $r.hvci_running = ($running -contains 2)
        $r.credential_guard_running = ($running -contains 1)
        # Protection de pile matérielle en mode noyau (5 ; 6 = audit, codes de la doc
        # Microsoft, À VÉRIFIER) : EAC et BattlEye refusent de charger leur pilote
        # quand elle est active. Rago ne l'active pas et ne la coupe pas : il la montre.
        $r.kernel_stack_protection = $(if ($running -contains 5) { 'on' } elseif ($running -contains 6) { 'audit' } else { 'off' })
        $r.hypervisor_support = ($avail -contains 1)
        $r.dma_protection = ($avail -contains 3)
    } catch { $r.errors += ('Win32_DeviceGuard : ' + $_.Exception.Message) }
    try { $r.hypervisor_present = [bool](Get-CimInstance -ClassName Win32_ComputerSystem).HypervisorPresent }
    catch { $r.errors += ('Win32_ComputerSystem : ' + $_.Exception.Message) }
    try { $r.secure_boot = [bool](Confirm-SecureBootUEFI) }
    catch { $r.secure_boot = $false; $r.errors += ('Secure Boot : ' + $_.Exception.Message) }
    try {
        $t = Get-Tpm
        $r.tpm_present = [bool]$t.TpmPresent
        $r.tpm_ready = [bool]$t.TpmReady
    } catch { $r.errors += ('Get-Tpm : ' + $_.Exception.Message) }
    try {
        $w = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm
        if ($null -ne $w) { $r.tpm_version = ([string]$w.SpecVersion).Split(',')[0].Trim() }
    } catch { $r.errors += ('Win32_Tpm : ' + $_.Exception.Message) }
    try {
        $v = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config' -Name VulnerableDriverBlocklistEnable -ErrorAction Stop
        $r.vulnerable_driver_blocklist = ($v.VulnerableDriverBlocklistEnable -eq 1)
    } catch { $r.vulnerable_driver_blocklist = $null }
    return $r
}

function Get-RagoEffective {
    param($Running)
    if ($Running.vbs -eq 'running' -and $Running.hvci_running) { return 'compat_max' }
    if ($Running.vbs -ne 'running' -and -not $Running.hvci_running) { return 'perf' }
    return 'mixed'
}

function Get-RagoWindowsVersion {
    $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $ubr = $null
    if ($cv.PSObject.Properties.Name -contains 'UBR') { $ubr = $cv.UBR }
    $disp = $null
    if ($cv.PSObject.Properties.Name -contains 'DisplayVersion') { $disp = $cv.DisplayVersion }
    return [ordered]@{ build = [int]$cv.CurrentBuild; ubr = $ubr; display_version = $disp; edition = $cv.EditionID; product = $cv.ProductName }
}

# Conditions de Vanguard On-Demand (pages Riot « Vanguard Pre-Check », juin 2026,
# relevées par l'étude M5) : rapportées, jamais « simulées ». Le verdict qui
# compte est celui de Riot (application VGTray). IOMMU : Riot vérifie qu'il est
# activé dans le BIOS ; on le lit ici comme « protection DMA » disponible pour VBS
# (AvailableSecurityProperties 3), pas comme « Kernel DMA Protection » (À VÉRIFIER).
function Get-RagoVanguardPrereqs {
    param($Running, $Version)
    $missing = @()
    if (-not $Running.secure_boot) { $missing += 'secure_boot' }
    if (-not ($Running.tpm_present -and $Running.tpm_ready -and $Running.tpm_version -eq '2.0')) { $missing += 'tpm_2.0' }
    if ($Running.vbs -ne 'running') { $missing += 'vbs' }
    if (-not $Running.hvci_running) { $missing += 'hvci' }
    if (-not $Running.dma_protection) { $missing += 'iommu' }
    if ($Version.build -lt 26200) { $missing += 'windows_11_25h2' }
    return [ordered]@{ ok = ($missing.Count -eq 0); missing = $missing; note = 'liste Riot (Vanguard Pre-Check, juin 2026) relevee par Rago ; le verdict officiel est dans VGTray' }
}

# Demande écrite par Linux : (valeur, source, profil, erreur).
function Get-RagoRequest {
    $root = Get-RagoCommRoot
    if ($null -eq $root) { return @{ value = 'compat_max'; source = 'rago-comm-absente'; id = $null; error = $null; root = $null } }
    $p = Join-Path $root 'security\profile.json'
    try { $req = Read-RagoJson $p }
    catch { return @{ value = 'compat_max'; source = 'invalide'; id = $null; error = $_.Exception.Message; root = $root } }
    if ($null -eq $req) { return @{ value = 'compat_max'; source = 'aucune-demande'; id = $null; error = $null; root = $root } }
    $ok = ($req.PSObject.Properties.Name -contains 'schema') -and ($req.schema -eq 1) -and
          ($req.PSObject.Properties.Name -contains 'kind') -and ($req.kind -eq 'rago-windows-security') -and
          ($req.PSObject.Properties.Name -contains 'security') -and (Test-RagoSecurityValue $req.security)
    if (-not $ok) { return @{ value = 'compat_max'; source = 'invalide'; id = $null; error = 'profile.json : schema/kind/security inattendus'; root = $root } }
    $id = $null
    if ($req.PSObject.Properties.Name -contains 'profile_id') { $id = $req.profile_id }
    return @{ value = $req.security; source = 'rago-comm'; id = $id; error = $null; root = $root }
}

function Write-RagoSecurityStatus {
    param($Status, $CommRoot)
    Write-RagoJson -Path $LocalStatusPath -InputObject $Status
    if ($null -ne $CommRoot) {
        try { Write-RagoJson -Path (Join-Path $CommRoot 'security\status.json') -InputObject $Status }
        catch { Write-RagoLog ('écriture de status.json dans RAGO-COMM impossible : ' + $_.Exception.Message) 'ERROR' }
    }
}

function Request-RagoRebootToWindows {
    # BootNext = Windows Boot Manager : le redémarrage revient sur Windows et pas
    # sur Linux (l'entrée à usage unique de Linux a déjà été consommée). C'est
    # une entrée à usage unique : l'ordre de démarrage n'est pas modifié.
    $code = Invoke-Bcdedit @('/set', '{fwbootmgr}', 'bootsequence', '{bootmgr}')
    return ($code -eq 0)
}

# --- main -----------------------------------------------------------------------------------
$errors = @()
$bootId = Get-RagoBootId
$state = Get-RagoSecurityState

if ($Status) {
    $running = Get-RagoSecurityRunning
    $ver = Get-RagoWindowsVersion
    [ordered]@{ configured = $state.configured; effective = (Get-RagoEffective $running); running = $running; windows = $ver;
        vanguard_on_demand_prereqs = (Get-RagoVanguardPrereqs $running $ver) } | ConvertTo-Json -Depth 8
    exit 0
}

if (-not ($Apply -or $Set)) {
    Write-Error 'usage : rago-security.ps1 -Apply | -Set compat_max|perf | -Status [-NoReboot]'
    exit 2
}

if ($Set) { $req = @{ value = $Set; source = 'manuel'; id = $null; error = $null; root = (Get-RagoCommRoot) } }
else { $req = Get-RagoRequest }
if ($req.error) { $errors += $req.error }
$desired = $req.value
Write-RagoLog ('démarrage {0} : demandé {1} (source {2}, profil {3}), en place {4}' -f $bootId, $desired, $req.source, $req.id, $state.configured)

$changed = $false
$fixed = @()
try {
    $fixed = @(Set-RagoBaseline)
    foreach ($f in $fixed) { Write-RagoLog ('base de sécurité corrigée : ' + $f) 'WARN' }
    if ($state.configured -ne $desired) {
        Set-RagoProfile $desired
        $changed = $true
        $state = [pscustomobject]@{ configured = $desired; changed_at = (Get-RagoUtcNow); reboot_for = $state.reboot_for; reboot_at = $state.reboot_at }
        Save-RagoSecurityState $state
        Write-RagoLog ('profil {0} posé (prend effet au prochain démarrage)' -f $desired)
    }
} catch {
    $errors += ('application du profil : ' + $_.Exception.Message)
    Write-RagoLog $errors[-1] 'ERROR'
}

$running = Get-RagoSecurityRunning
$errors += @($running.errors)
$effective = Get-RagoEffective $running
$ver = Get-RagoWindowsVersion

# Redémarrage : seulement si la configuration a changé pendant ce démarrage
# (ou si la base compat_max a dû être corrigée alors que compat_max est demandé).
$needReboot = $changed -or ($desired -eq 'compat_max' -and $fixed.Count -gt 0 -and $effective -ne 'compat_max')
$reboot = 'none'
if ($needReboot) {
    $recent = $false
    if ($state.reboot_for -eq $desired -and $state.reboot_at) {
        try { $recent = ((Get-Date).ToUniversalTime() - [datetime]::Parse($state.reboot_at).ToUniversalTime()).TotalMinutes -lt $LoopGuardMinutes } catch { $recent = $false }
    }
    if ($NoReboot) { $reboot = 'pending_next_boot' }
    elseif ($recent) {
        $reboot = 'loop_guard'
        $errors += ('déjà redémarré pour {0} il y a moins de {1} min : pas de nouvelle boucle' -f $desired, $LoopGuardMinutes)
    } elseif (Request-RagoRebootToWindows) { $reboot = 'started' }
    else {
        $reboot = 'needed_no_bootnext'
        $errors += 'BootNext vers Windows impossible : profil appliqué au prochain démarrage de Windows'
    }
}
if ($reboot -eq 'started') {
    $state = [pscustomobject]@{ configured = $state.configured; changed_at = $state.changed_at; reboot_for = $desired; reboot_at = (Get-RagoUtcNow) }
    Save-RagoSecurityState $state
}

$status = [ordered]@{
    schema = 1
    kind = 'rago-windows-security-status'
    boot_id = $bootId
    written_at = (Get-RagoUtcNow)
    requested = $desired
    requested_profile_id = $req.id
    request_source = $req.source
    configured = $state.configured
    effective = $effective
    reboot = $reboot
    baseline_fixed = $fixed
    running = $running
    windows = $ver
    vanguard_on_demand_prereqs = (Get-RagoVanguardPrereqs $running $ver)
    errors = $errors
}
Write-RagoSecurityStatus $status $req.root
Write-RagoLog ('état : configuré {0}, effectif {1}, redémarrage {2}' -f $state.configured, $effective, $reboot)

if ($reboot -eq 'started') {
    Write-RagoLog 'redémarrage vers Windows pour appliquer le profil'
    & "$env:SystemRoot\System32\shutdown.exe" /r /t 0 /d p:2:4
}
exit 0
