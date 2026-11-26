# SPDX-License-Identifier: GPL-2.0
<#
.SYNOPSIS
    Shell provisoire du micro-Windows Rago (module M5), à la place d'explorer.exe.

.DESCRIPTION
    Lancé par Winlogon (valeur Shell, posée par compile_micro_engine.ps1 et
    reposée par rago-boot.ps1) à l'ouverture de session automatique du
    joueur. Pas de bureau, pas de barre des tâches, pas d'explorer.exe.

      1. attend l'état de sécurité de CE démarrage (écrit par rago-security.ps1,
         tâche \Rago\Boot, compte SYSTEM) ; si un redémarrage est lancé pour
         appliquer le profil demandé par Linux, il l'annonce et ne fait rien ;
      2. affiche le profil demandé et l'état RÉEL (VBS, HVCI, Secure Boot, TPM) ;
      3. bibliothèque partagée (M7) : ouvre la fenêtre de l'agent
         (C:\Rago\agent\rago-agent.ps1 -Session) qui prend les requêtes de
         Linux et suit les installations ; elle se ferme seule quand il n'y a
         plus rien en cours ;
      4. propose un petit menu de maintenance : console, console
         administrateur (UAC), navigateur, lancer un programme, rapport M5,
         bibliothèque, retour à Linux (redémarrage), arrêt.

    Le lancement direct du jeu et le retour automatique vers Linux sont le
    travail de M6 (Fast OS Switch) : ce shell sera remplacé.

    Gestionnaire des tâches : Ctrl+Maj+Échap. Si ce shell est fermé :
    Ctrl+Alt+Suppr > Gestionnaire des tâches > Exécuter une nouvelle tâche >
    powershell -File C:\Rago\bin\rago-shell.ps1
#>
[CmdletBinding()]
param([int]$WaitSeconds = 120)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot 'RagoComm.psm1') -Force
Set-RagoLogName 'shell'

$Host.UI.RawUI.WindowTitle = 'Rago - micro-Windows (M5)'
$statusPath = Join-Path (Get-RagoDataDir) 'security-status.json'
$agent = Join-Path (Get-RagoRootDir) 'agent\rago-agent.ps1'
$ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

# Fenêtre de l'agent de la bibliothèque (M7), compte du joueur.
function Start-RagoLibrarySession {
    if (-not (Test-Path -LiteralPath $agent)) { Write-Host 'Bibliothèque : agent absent de cette image (C:\Rago\agent).'; return }
    Start-Process -FilePath $ps -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $agent, '-Session', '-WaitSeconds', '300')
}

function Invoke-RagoLibraryMenu {
    if (-not (Test-Path -LiteralPath $agent)) { Write-Host 'Bibliothèque : agent absent de cette image (C:\Rago\agent).'; return }
    & $ps -NoLogo -NoProfile -ExecutionPolicy Bypass -File $agent -Status
    Write-Host '[R] Relancer la fenêtre de la bibliothèque   [A] Abandonner une requête   [Entrée] Retour'
    $b = Read-Host 'Choix'
    if ($null -eq $b) { return }
    switch ($b.Trim().ToUpperInvariant()) {
        'R' { Start-RagoLibrarySession }
        'A' {
            $id = Read-Host 'Identifiant de la requête (ex. install-steam-730)'
            if ($id) { & $ps -NoLogo -NoProfile -ExecutionPolicy Bypass -File $agent -Abandon $id.Trim() }
        }
        default { }
    }
}

function Read-RagoStatusForThisBoot {
    param([string]$BootId)
    try { $s = Read-RagoJson $statusPath } catch { return $null }
    if ($null -eq $s) { return $null }
    if (-not ($s.PSObject.Properties.Name -contains 'boot_id') -or $s.boot_id -ne $BootId) { return $null }
    return $s
}

function Show-RagoStatus {
    param($S)
    if ($null -eq $S) {
        Write-Host ("Etat de securite de ce demarrage : pas encore ecrit apres {0} s (journal : {1})" -f $WaitSeconds, (Join-Path (Get-RagoDataDir) 'logs\security.log')) -ForegroundColor Yellow
        return
    }
    $r = $S.running
    Write-Host ('Profil demandé par Linux : {0} (source {1}, jeu {2})' -f $S.requested, $S.request_source, $S.requested_profile_id)
    Write-Host ('Profil en place          : {0} ; effectif : {1}' -f $S.configured, $S.effective)
    Write-Host ('VBS {0} ; HVCI {1} ; Secure Boot {2} ; TPM {3} (version {4}) ; protection DMA {5}' -f $r.vbs, $r.hvci_running, $r.secure_boot, $r.tpm_ready, $r.tpm_version, $r.dma_protection)
    if ($r.PSObject.Properties.Name -contains 'kernel_stack_protection' -and $r.kernel_stack_protection -ne 'off') {
        Write-Host ('Protection de pile matérielle en mode noyau : {0} (EAC et BattlEye ne chargent pas leur pilote avec elle ; réglage : Sécurité Windows > Sécurité des appareils > Isolation du noyau)' -f $r.kernel_stack_protection) -ForegroundColor Yellow
    }
    $v = $S.vanguard_on_demand_prereqs
    if ($v.ok) { Write-Host 'Conditions Vanguard On-Demand (liste Riot relevée par Rago ; verdict officiel dans VGTray) : remplies' -ForegroundColor Green }
    else { Write-Host ('Conditions Vanguard On-Demand (liste Riot relevée par Rago ; verdict officiel dans VGTray) : manque {0}' -f (@($v.missing) -join ', ')) -ForegroundColor Yellow }
    foreach ($e in @($S.errors)) { if ($e) { Write-Host ('  ! ' + $e) -ForegroundColor Yellow } }
}

function Show-RagoLastReport {
    $dir = Join-Path (Get-RagoDataDir) 'reports'
    $last = Get-ChildItem -LiteralPath $dir -Filter 'm5-engine-*.json' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
    if ($null -eq $last) { Write-Host 'Pas encore de rapport (il est écrit environ une minute après l''ouverture de session).'; return }
    try { $j = Read-RagoJson $last.FullName } catch { Write-Host ('Rapport illisible : ' + $_.Exception.Message); return }
    Write-Host ('Rapport {0}' -f $last.FullName)
    Write-Host ('  RAM utilisée au repos : {0} Mio sur {1} Mio' -f $j.ram.in_use_mib, $j.ram.total_mib)
    Write-Host ('  explorer.exe : {0} ; SearchIndexer : {1} ; processus : {2} ; services actifs : {3}' -f $j.explorer_running, $j.search_indexer_running, $j.process_count, $j.services_running_count)
    Write-Host ('  C: occupé sans pagefile / hiberfil / swapfile : {0} Mio' -f $j.disk.c_used_without_page_hiber_swap_mib)
}

function Invoke-RagoChoice {
    param([string]$Choice)
    switch ($Choice.Trim().ToUpperInvariant()) {
        '1' { & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo; break }
        '2' { Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList '-NoLogo' -Verb RunAs; break }
        '3' {
            $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") |
                Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
            if ($edge) { Start-Process -FilePath $edge } else { Write-Host 'Microsoft Edge absent de cette image.' }
            break
        }
        '4' {
            $p = Read-Host 'Chemin complet du programme (launcher, installateur)'
            if ($p) {
                try { Start-Process -FilePath $p.Trim('"') } catch { Write-Host ('Impossible : ' + $_.Exception.Message) }
            }
            break
        }
        '5' { Show-RagoLastReport; break }
        'B' { Invoke-RagoLibraryMenu; break }
        'S' { Show-RagoStatus (Read-RagoStatusForThisBoot (Get-RagoBootId)); break }
        'L' {
            Write-RagoLog 'retour à Linux demandé (redémarrage)'
            & "$env:SystemRoot\System32\shutdown.exe" /r /t 0 /d p:0:0
            break
        }
        'E' {
            Write-RagoLog 'arrêt demandé'
            & "$env:SystemRoot\System32\shutdown.exe" /s /t 0 /d p:0:0
            break
        }
        default { Write-Host 'Choix inconnu.' }
    }
}

# --- 1. état de sécurité de ce démarrage ------------------------------------------------------
Write-Host 'Rago OS - micro-Windows (M5, shell provisoire)' -ForegroundColor Cyan
$bootId = Get-RagoBootId
$status = $null
$deadline = (Get-Date).AddSeconds($WaitSeconds)
Write-Host 'Application du profil de sécurité demandé par Linux...'
while ($null -eq $status -and (Get-Date) -lt $deadline) {
    $status = Read-RagoStatusForThisBoot $bootId
    if ($null -eq $status) { Start-Sleep -Seconds 1 }
}
Write-RagoLog ('shell démarré (démarrage {0}, état {1})' -f $bootId, $(if ($null -eq $status) { 'absent' } else { $status.reboot }))
if ($null -ne $status -and $status.reboot -eq 'started') {
    Write-Host ('Redémarrage de Windows pour appliquer le profil {0} (une seule fois)...' -f $status.requested) -ForegroundColor Yellow
    while ($true) { Start-Sleep -Seconds 60 }
}

# --- 2. affichage ------------------------------------------------------------------------------
Show-RagoStatus $status

# --- 3. bibliothèque partagée (M7) ----------------------------------------------------------------
try { Start-RagoLibrarySession } catch { Write-Host ('Bibliothèque : ' + $_.Exception.Message) -ForegroundColor Yellow }

# --- 4. menu de maintenance ----------------------------------------------------------------------
while ($true) {
    Write-Host ''
    Write-Host '[1] Console   [2] Console administrateur   [3] Navigateur   [4] Lancer un programme'
    Write-Host '[5] Rapport M5   [B] Bibliotheque   [S] Etat de securite   [L] Retour a Linux (redemarrer)   [E] Eteindre'
    $c = Read-Host 'Choix'
    if ($null -eq $c) { continue }
    Invoke-RagoChoice $c
}
