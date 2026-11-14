# SPDX-License-Identifier: GPL-2.0
<#
.SYNOPSIS
    Premier démarrage du micro-Windows Rago (module M5), compte SYSTEM.

.DESCRIPTION
    Lancé deux fois, avec le même résultat (idempotent) :
      -Phase specialize      par autounattend.xml (Microsoft-Windows-Deployment,
                             RunSynchronous, passe specialize, contexte système) ;
      -Phase setupcomplete   par C:\Windows\Setup\Scripts\SetupComplete.cmd ou, si
                             Windows ne l'a pas lancé (clé OEM : doc Microsoft),
                             par rago-boot.ps1 au premier démarrage.

    specialize (rien qui dépende du compte du joueur ni de l'écran d'accueil) :
      1. dossiers de Rago verrouillés (C:\Rago et C:\ProgramData\Rago :
         SYSTEM et Administrateurs seuls en écriture, ils sont lancés en SYSTEM) ;
      2. tâche planifiée \Rago\Boot (C:\Rago\tasks\rago-boot.xml) ;
      3. hibernation coupée (défaut : le micro-Windows est sans état, seul Linux
         hiberne au switch) ou, si la construction l'a demandé (-Hibernation
         full), gardée ; démarrage rapide (« Fast Startup ») toujours coupé ;
      4. fichier d'échange : taille fixe minimale (pagefile_mb) ;
      5. démarrage de Windows : pas de réparation automatique en boucle (WinRE
         est retiré de l'image), pas d'attente au menu ;
      6. profil de sécurité initial (rago-security.ps1 -Apply -NoReboot).
    setupcomplete (en plus) :
      7. le joueur dans Administrateurs (par SID, UAC actif) ; ouverture de session
         automatique et shell Rago (rago-boot.ps1 -SettingsOnly) ;
      8. CompactOS vérifié (posé s'il manque) ;
      9. bibliothèques fournies par le joueur dans C:\Rago\redist (VC++, DirectX) ;
     10. ménage : C:\$Windows.~BT, C:\$Windows.~WS, C:\Windows.old.
    Réglages lus dans C:\Rago\micro-engine.json (écrit par compile_micro_engine.ps1).
    Résultat : C:\ProgramData\Rago\firstboot-<phase>.json (aucune valeur inventée).
    Le shell n'est pas posé en specialize : rien ne doit gêner l'écran d'accueil
    (OOBE). Au pire, la première session après l'installation s'ouvre une fois
    avec explorer.exe.
#>
[CmdletBinding()]
param([Parameter(Mandatory = $true)][ValidateSet('specialize', 'setupcomplete')][string]$Phase)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$bin = Join-Path $env:SystemDrive 'Rago\bin'
Import-Module (Join-Path $bin 'RagoComm.psm1') -Force
Set-RagoLogName 'firstboot'

$steps = [ordered]@{}
$errors = @()
function Step {
    param([string]$Name, [scriptblock]$Body)
    try {
        $r = & $Body
        $steps[$Name] = $(if ($null -eq $r) { 'ok' } else { $r })
        Write-RagoLog ('{0} : {1}' -f $Name, ($steps[$Name] | Out-String).Trim())
    } catch {
        $steps[$Name] = 'erreur'
        $script:errors += ('{0} : {1}' -f $Name, $_.Exception.Message)
        Write-RagoLog $script:errors[-1] 'ERROR'
    }
}

function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)
    $out = & $Exe @Arguments 2>&1
    $code = $LASTEXITCODE
    $text = ($out | Out-String).Trim()
    if ($code -ne 0) { throw ('{0} {1} -> code {2} : {3}' -f $Exe, ($Arguments -join ' '), $code, $text) }
    return $text
}

$sys32 = Join-Path $env:SystemRoot 'System32'
$info = Read-RagoJson (Join-Path (Get-RagoRootDir) 'micro-engine.json')
if ($null -eq $info) { throw 'C:\Rago\micro-engine.json absent : image non construite par compile_micro_engine.ps1' }
Write-RagoLog ('phase {0} (image {1}, construite le {2})' -f $Phase, $info.image.edition, $info.built_at)

# 1. dossiers verrouillés -----------------------------------------------------------------------
# Les scripts de C:\Rago tournent en SYSTEM : un dossier modifiable par un compte
# standard (ACL héritée de C:\) serait une élévation de privilèges.
Step 'acl' {
    $icacls = Join-Path $sys32 'icacls.exe'
    foreach ($d in @((Get-RagoRootDir), (Get-RagoDataDir))) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        Invoke-Native $icacls @($d, '/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-32-545:(OI)(CI)RX', '/T', '/C', '/Q') | Out-Null
    }
    return 'C:\Rago et C:\ProgramData\Rago : SYSTEM et Administrateurs en écriture, Utilisateurs en lecture'
}

# 2. tâche de démarrage --------------------------------------------------------------------------
Step 'tache_boot' {
    $xml = [System.IO.File]::ReadAllText((Join-Path (Get-RagoRootDir) 'tasks\rago-boot.xml'))
    Register-ScheduledTask -TaskName 'Boot' -TaskPath '\Rago\' -Xml $xml -Force | Out-Null
    $t = Get-ScheduledTask -TaskName 'Boot' -TaskPath '\Rago\'
    return ('\Rago\Boot : {0}' -f $t.State)
}

# 3. hibernation / démarrage rapide ------------------------------------------------------------------
Step 'hibernation' {
    $powercfg = Join-Path $sys32 'powercfg.exe'
    # Sans réglage lisible : coupée (défaut de compile_micro_engine.ps1).
    $hib = 'off'
    if ($info.PSObject.Properties.Name -contains 'hibernation' -and $info.hibernation -eq 'full') { $hib = 'full' }
    if ($hib -eq 'full') {
        Invoke-Native $powercfg @('/hibernate', 'on') | Out-Null
        Invoke-Native $powercfg @('/hibernate', '/type', 'full') | Out-Null
    } else {
        Invoke-Native $powercfg @('/hibernate', 'off') | Out-Null
    }
    # Démarrage rapide = arrêt hybride : Windows laisserait ses volumes « en cours d'utilisation ».
    $p = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
    New-ItemProperty -LiteralPath $p -Name HiberbootEnabled -PropertyType DWord -Value 0 -Force | Out-Null
    return ('hibernation {0}, démarrage rapide coupé' -f $hib)
}

# 4. fichier d'échange : taille fixe ------------------------------------------------------------------
Step 'pagefile' {
    $mb = [int]$info.pagefile_mb
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    if ($cs.AutomaticManagedPagefile) { Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $false } }
    $name = Join-Path ($env:SystemDrive + '\') 'pagefile.sys'
    $pf = Get-CimInstance -ClassName Win32_PageFileSetting | Where-Object { $_.Name -eq $name }
    if ($null -eq $pf) {
        New-CimInstance -ClassName Win32_PageFileSetting -Property @{ Name = $name; InitialSize = [uint32]$mb; MaximumSize = [uint32]$mb } | Out-Null
    } else {
        Set-CimInstance -InputObject $pf -Property @{ InitialSize = [uint32]$mb; MaximumSize = [uint32]$mb }
    }
    return ('{0} : {1} Mio fixe (au prochain démarrage)' -f $name, $mb)
}

# 5. démarrage de Windows ---------------------------------------------------------------------------
Step 'bcd' {
    $bcd = Join-Path $sys32 'bcdedit.exe'
    Invoke-Native $bcd @('/set', '{current}', 'recoveryenabled', 'No') | Out-Null
    Invoke-Native $bcd @('/set', '{current}', 'bootstatuspolicy', 'IgnoreAllFailures') | Out-Null
    Invoke-Native $bcd @('/timeout', '0') | Out-Null
    return 'recoveryenabled No, bootstatuspolicy IgnoreAllFailures, timeout 0'
}

# 6. profil de sécurité initial (jamais de redémarrage pendant l'installation) ------------------------
Step 'securite' {
    & (Join-Path $bin 'rago-security.ps1') -Apply -NoReboot
    $s = Read-RagoJson (Join-Path (Get-RagoDataDir) 'security-status.json')
    if ($null -eq $s) { throw 'security-status.json absent' }
    return ('demandé {0}, posé {1}, effectif {2}' -f $s.requested, $s.configured, $s.effective)
}

# --- setupcomplete seulement ----------------------------------------------------------------------
if ($Phase -eq 'setupcomplete') {

# 7. compte du joueur, session automatique et shell
Step 'session' {
    $player = [string]$info.player
    $u = Get-LocalUser -Name $player -ErrorAction SilentlyContinue
    if ($null -eq $u) { throw ('compte {0} introuvable (passe oobeSystem pas encore faite ?) : rago-boot.ps1 réessaiera' -f $player) }
    # Administrateurs par SID (S-1-5-32-544) : indépendant de la langue de Windows.
    # Sans droits d'administrateur (avec UAC), le joueur ne pourrait installer ni jeu ni anti-triche.
    $admins = Get-LocalGroup -SID 'S-1-5-32-544'
    try { Add-LocalGroupMember -Group $admins -Member $u -ErrorAction Stop }
    catch [Microsoft.PowerShell.Commands.MemberExistsException] { }
    & (Join-Path $bin 'rago-boot.ps1') -SettingsOnly
    return ('{0} administrateur (UAC actif), ouverture de session automatique et shell Rago posés' -f $player)
}

# 8. CompactOS ----------------------------------------------------------------------------------
Step 'compactos' {
    if (-not $info.compact_os) { return 'non demandé' }
    # Test par la taille compressée de fichiers système (indépendant de la langue,
    # contrairement au texte de « compact /CompactOS:query »).
    $c = Test-RagoCompactOS
    if ($c -eq $true) { return 'déjà en CompactOS' }
    $compact = Join-Path $sys32 'compact.exe'
    $out = (& $compact /CompactOS:always 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw ('compact /CompactOS:always : code {0}' -f $LASTEXITCODE) }
    return ('compact /CompactOS:always lancé (test avant : {0}) : {1}' -f $c, ($out -split "`n" | Select-Object -Last 1))
}

# 9. bibliothèques du joueur (BYOL : Rago ne les fournit pas) -----------------------------------------
Step 'redist' {
    $dir = Join-Path (Get-RagoRootDir) 'redist'
    if (-not (Test-Path -LiteralPath $dir)) { return 'aucune (C:\Rago\redist absent)' }
    $done = @()
    foreach ($vc in @(Get-ChildItem -LiteralPath $dir -Filter 'VC_redist.*.exe' -File | Sort-Object Name)) {
        $p = Start-Process -FilePath $vc.FullName -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru
        # 0 = installé, 3010 = redémarrage demandé, 1638 = version égale ou plus récente déjà là.
        if (@(0, 1638, 3010) -notcontains $p.ExitCode) { throw ('{0} : code {1}' -f $vc.Name, $p.ExitCode) }
        $done += ('{0}={1}' -f $vc.Name, $p.ExitCode)
    }
    $dx = Get-ChildItem -LiteralPath $dir -Filter 'DXSETUP.exe' -File -Recurse | Select-Object -First 1
    if ($null -ne $dx) {
        $p = Start-Process -FilePath $dx.FullName -ArgumentList '/silent' -Wait -PassThru -WorkingDirectory $dx.DirectoryName
        if ($p.ExitCode -ne 0) { throw ('DXSETUP : code {0}' -f $p.ExitCode) }
        $done += 'DXSETUP=0'
    }
    if ($done.Count -eq 0) { return 'aucune' }
    return ($done -join ', ')
}

# 10. ménage -----------------------------------------------------------------------------------------
Step 'menage' {
    $gone = @()
    foreach ($d in @('$Windows.~BT', '$Windows.~WS', 'Windows.old')) {
        $p = Join-Path ($env:SystemDrive + '\') $d
        if (Test-Path -LiteralPath $p) {
            Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $p)) { $gone += $d } else { $script:errors += ('ménage : {0} pas entièrement supprimé' -f $d) }
        }
    }
    if ($gone.Count -eq 0) { return 'rien à supprimer' }
    return ('supprimé : ' + ($gone -join ', '))
}

}

$result = [ordered]@{
    schema = 1
    kind = 'rago-m5-firstboot'
    phase = $Phase
    written_at = (Get-RagoUtcNow)
    steps = $steps
    errors = $errors
}
Write-RagoJson -Path (Join-Path (Get-RagoDataDir) ("firstboot-{0}.json" -f $Phase)) -InputObject $result
# Jamais d'échec vers Windows Setup : une erreur ici ne doit pas bloquer l'installation
# (elle est écrite dans le résultat et le journal, et rago-boot.ps1 repasse à chaque démarrage).
exit 0
