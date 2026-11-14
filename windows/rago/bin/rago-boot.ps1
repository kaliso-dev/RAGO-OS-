# SPDX-License-Identifier: GPL-2.0
<#
.SYNOPSIS
    Tâche de démarrage du micro-Windows Rago (module M5), compte SYSTEM.

.DESCRIPTION
    Lancée à chaque démarrage par la tâche planifiée \Rago\Boot
    (C:\Rago\tasks\rago-boot.xml, posée par C:\Rago\setup\firstboot.ps1),
    en parallèle de l'ouverture de session automatique :

      1. garde l'ouverture de session automatique du joueur (AutoAdminLogon,
         sans compteur) : aucun écran de connexion, jamais ;
      2. garde le shell Rago à la place d'explorer.exe (Winlogon\Shell) ;
      2 bis. pas de mise à jour en ligne (décision du 14/11) : wuauserv coupé et
         stratégie NoAutoUpdate ; le réparateur de Windows Update, gardé, peut
         rallumer wuauserv : il est recoupé par le gestionnaire de services
         (effet immédiat) et c'est noté
         (C:\ProgramData\Rago\windows-update-guard.json, rapport M5) ;
         étapes 1, 2 et 2 bis aussi en -SettingsOnly (installation) ;
      3. applique le profil de sécurité demandé par Linux
         (rago-security.ps1 -Apply ; peut redémarrer une fois sur Windows) ;
      4. si Windows ne redémarre pas : rapport de mesure M5 (rago-report.ps1),
         une minute après l'ouverture de la session du joueur ;
      5. définitions de Defender : Windows Update est coupé dans le
         micro-Windows, elles sont donc prises directement chez Microsoft
         (MpCmdRun -SignatureUpdate -MMPC, 5 min au plus).
    Au premier démarrage, si la fin d'installation n'a pas tourné
    (SetupComplete.cmd), elle est lancée avant l'étape 3.

    Le shell (rago-shell.ps1 de M5, puis celui de M6) attend
    C:\ProgramData\Rago\security-status.json de ce démarrage avant de lancer quoi que ce soit.
#>
[CmdletBinding()]
param(
    # Étapes 1, 2 et 2 bis seulement (firstboot.ps1, pendant l'installation).
    [switch]$SettingsOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RagoComm.psm1') -Force
Set-RagoLogName 'boot'

function Set-RagoAutoLogon {
    $info = $null
    try { $info = Read-RagoJson (Join-Path (Get-RagoRootDir) 'micro-engine.json') } catch { $info = $null }
    $user = 'RagoPlayer'
    if ($null -ne $info -and $info.PSObject.Properties.Name -contains 'player') { $user = [string]$info.player }
    $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $want = [ordered]@{ AutoAdminLogon = '1'; DefaultUserName = $user; DefaultDomainName = $env:COMPUTERNAME; DefaultPassword = '' }
    foreach ($k in $want.Keys) {
        $cur = Get-ItemProperty -LiteralPath $wl -Name $k -ErrorAction SilentlyContinue
        if ($null -eq $cur -or [string]$cur.$k -ne $want[$k]) {
            New-ItemProperty -LiteralPath $wl -Name $k -PropertyType String -Value $want[$k] -Force | Out-Null
            Write-RagoLog ('Winlogon\{0} reposé' -f $k)
        }
    }
    # AutoLogonCount : à 0 Windows coupe l'ouverture automatique. Sans lui, elle est permanente.
    if ($null -ne (Get-ItemProperty -LiteralPath $wl -Name AutoLogonCount -ErrorAction SilentlyContinue)) {
        Remove-ItemProperty -LiteralPath $wl -Name AutoLogonCount -Force
        Write-RagoLog 'Winlogon\AutoLogonCount retiré (ouverture automatique permanente)'
    }
}

function Set-RagoShell {
    $info = $null
    try { $info = Read-RagoJson (Join-Path (Get-RagoRootDir) 'micro-engine.json') } catch { $info = $null }
    if ($null -eq $info -or -not ($info.PSObject.Properties.Name -contains 'shell') -or -not $info.shell) { return }
    $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $cur = Get-ItemProperty -LiteralPath $wl -Name Shell -ErrorAction SilentlyContinue
    if ($null -eq $cur -or [string]$cur.Shell -ne [string]$info.shell) {
        New-ItemProperty -LiteralPath $wl -Name Shell -PropertyType String -Value ([string]$info.shell) -Force | Out-Null
        Write-RagoLog 'Winlogon\Shell reposé (shell Rago, pas explorer.exe)'
    }
}

# Pas de mise à jour en ligne au runtime (décision du 14/11) : wuauserv coupé +
# stratégie NoAutoUpdate ; l'orchestrateur et le réparateur de Windows Update
# sont gardés (guide Microsoft des services d'IoT Enterprise) et jamais touchés
# ici. Si le réparateur a rallumé wuauserv, on le recoupe PAR LE GESTIONNAIRE DE
# SERVICES (Set-Service : effet immédiat ; une écriture directe dans le registre
# ne compterait qu'au démarrage suivant), on l'arrête sans attendre plus de 30 s,
# et on le note. Les correctifs passent par -UpdatePath (construction).
function Set-RagoNoOnlineUpdate {
    $guard = [ordered]@{
        boot_id = (Get-RagoBootId); checked_at = (Get-RagoUtcNow)
        wuauserv_start_mode_found = $null; wuauserv_recut = $false; wuauserv_start_mode_after = $null
        wuauserv_stopped = $null; no_auto_update_reset = $false; errors = @()
    }
    try {
        $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name = 'wuauserv'" -ErrorAction SilentlyContinue
        if ($null -ne $svc) {
            $guard.wuauserv_start_mode_found = [string]$svc.StartMode
            if ([string]$svc.StartMode -ne 'Disabled') {
                try {
                    Set-Service -Name wuauserv -StartupType Disabled
                    $guard.wuauserv_recut = $true
                    Write-RagoLog ('wuauserv retrouvé en {0} (réparateur de Windows Update ?) : recoupé' -f $svc.StartMode) 'WARN'
                } catch { $guard.errors += ('Set-Service wuauserv : ' + $_.Exception.Message) }
            }
            $s = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
            if ($null -ne $s -and $s.Status -ne 'Stopped') {
                try {
                    if ($s.Status -ne 'StopPending') { $s.Stop() }
                    $s.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
                    $guard.wuauserv_stopped = $true
                } catch {
                    $guard.wuauserv_stopped = $false
                    $guard.errors += ('arrêt de wuauserv : ' + $_.Exception.Message)
                }
            }
            $after = Get-CimInstance -ClassName Win32_Service -Filter "Name = 'wuauserv'" -ErrorAction SilentlyContinue
            if ($null -ne $after) { $guard.wuauserv_start_mode_after = [string]$after.StartMode }
        }
        $au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
        if (-not (Test-Path -LiteralPath $au)) { New-Item -Path $au -Force | Out-Null }
        $v = Get-ItemProperty -LiteralPath $au -Name NoAutoUpdate -ErrorAction SilentlyContinue
        if ($null -eq $v -or [int]$v.NoAutoUpdate -ne 1) {
            New-ItemProperty -LiteralPath $au -Name NoAutoUpdate -PropertyType DWord -Value 1 -Force | Out-Null
            $guard.no_auto_update_reset = $true
            Write-RagoLog 'stratégie NoAutoUpdate reposée' 'WARN'
        }
    } catch {
        $guard.errors += $_.Exception.Message
    } finally {
        foreach ($e in $guard.errors) { Write-RagoLog ('Windows Update : ' + $e) 'ERROR' }
        Write-RagoJson -Path (Join-Path (Get-RagoDataDir) 'windows-update-guard.json') -InputObject $guard
    }
}

try { Set-RagoAutoLogon } catch { Write-RagoLog ('ouverture automatique : ' + $_.Exception.Message) 'ERROR' }
try { Set-RagoShell } catch { Write-RagoLog ('shell : ' + $_.Exception.Message) 'ERROR' }
try { Set-RagoNoOnlineUpdate } catch { Write-RagoLog ('Windows Update : ' + $_.Exception.Message) 'ERROR' }
if ($SettingsOnly) { return }

# Fin d'installation pas faite (SetupComplete.cmd non lancé par Windows, ou compte
# du joueur pas encore créé à ce moment-là) : on la fait maintenant, sans redémarrer.
$fb = $null
try { $fb = Read-RagoJson (Join-Path (Get-RagoDataDir) 'firstboot-setupcomplete.json') } catch { $fb = $null }
$fbSteps = $null
if ($null -ne $fb -and $fb.PSObject.Properties.Name -contains 'steps') { $fbSteps = $fb.steps }
if ($null -eq $fbSteps -or -not ($fbSteps.PSObject.Properties.Name -contains 'session') -or $fbSteps.session -eq 'erreur') {
    Write-RagoLog 'fin d''installation (firstboot.ps1 -Phase setupcomplete) lancée par la tâche de démarrage'
    try { & (Join-Path (Get-RagoRootDir) 'setup\firstboot.ps1') -Phase setupcomplete | Out-Null }
    catch { Write-RagoLog ('firstboot.ps1 : ' + $_.Exception.Message) 'ERROR' }
}

$sec = Join-Path $PSScriptRoot 'rago-security.ps1'
try { & $sec -Apply } catch { Write-RagoLog ('rago-security.ps1 : ' + $_.Exception.Message) 'ERROR' }

# Rapport M5 seulement si ce démarrage n'est pas déjà en train de redémarrer.
$st = $null
try { $st = Read-RagoJson (Join-Path (Get-RagoDataDir) 'security-status.json') } catch { $st = $null }
if ($null -ne $st -and $st.boot_id -eq (Get-RagoBootId) -and $st.reboot -eq 'started') { exit 0 }
try { & (Join-Path $PSScriptRoot 'rago-report.ps1') -SettleSeconds 60 -WaitForShell | Out-Null }
catch { Write-RagoLog ('rago-report.ps1 : ' + $_.Exception.Message) 'ERROR' }

# Définitions de Defender, après la mesure (pour ne pas la fausser). Windows
# Update est coupé : source MMPC (centre Microsoft de protection contre les
# programmes malveillants), documentée pour MpCmdRun. À vérifier sur la machine.
$mp = Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'
if (Test-Path -LiteralPath $mp) {
    try {
        $p = Start-Process -FilePath $mp -ArgumentList @('-SignatureUpdate', '-MMPC') -WindowStyle Hidden -PassThru
        if ($p.WaitForExit(300000)) { Write-RagoLog ('définitions Defender (MMPC) : code {0}' -f $p.ExitCode) }
        else { Write-RagoLog 'définitions Defender (MMPC) : plus de 5 min, laissé en fond' 'WARN' }
    } catch { Write-RagoLog ('définitions Defender : ' + $_.Exception.Message) 'WARN' }
} else {
    Write-RagoLog ('définitions Defender : {0} absent' -f $mp) 'WARN'
}
exit 0
