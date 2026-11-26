# SPDX-License-Identifier: GPL-2.0
<#
.SYNOPSIS
    Construit le micro-Windows de Rago OS (module M5) par ablation DISM hors
    ligne d'une image Windows 11 FOURNIE PAR LE JOUEUR (BYOL).

.DESCRIPTION
    Rago ne distribue JAMAIS Windows. Ce script ne télécharge rien : il refuse de
    tourner sans une ISO (ou un dossier de média, ou un install.wim / install.esd)
    que le joueur a obtenue lui-même chez Microsoft, pour sa licence.

    Méthode (liste dans micro_engine_plan.json ; explications dans
    docs/vault/Modules/M5 Micro-Windows.md) :
      0. vérifications : administrateur, Windows, DISM assez récent, plan sûr
         (aucun service de sécurité coupé, base VBS + HVCI présente), édition et
         build. Base décidée par Sofiene le 14/11 : Windows 11 Pro 25H2 ou plus
         (build 26200+, minimum de Vanguard On-Demand). Refus sous 26200 sauf
         -AllowOlderBuild ; une autre édition seulement si -Edition / -Index la
         demande (avertissement ; licence des éditions IoT / LTSC) ;
      1. l'édition choisie est exportée dans une image de travail et montée ;
         option -UpdatePath : mises à jour cumulatives (.msu / .cab) du joueur
         (celle de .NET, « ndp », seulement après .NET 3.5, étape 7) ;
      2. paquets Appx provisionnés (Store / UWP) retirés ;
      3. fonctions à la demande, langues et packs de langue en trop retirés,
         fonctionnalités inutiles désactivées (SMB1, impression, fax, PowerShell 2...) ;
      4. pilotes : pilotes tiers des classes inutiles retirés, pilotes du joueur
         ajoutés (-DriverPath). Les pilotes inbox ne sont pas retirables par DISM ;
      5. ruches hors ligne : services de bruit / d'interface coupés (jamais ceux de
         la sécurité), base VBS + HVCI posée puis RELUE, télémétrie, Fast Startup ;
      6. charge utile Rago : C:\Rago (verrouillé), SetupComplete.cmd, micro-engine.json,
         agent de la bibliothèque partagée (M7, C:\Rago\agent, depuis -AgentPath) ;
      7. magasin de composants nettoyé (StartComponentCleanup + ResetBase), puis
         .NET 3.5 depuis l'ISO, puis sauvegardes, caches, journaux et WinRE effacés ;
      8. démontage, export final : max (LZX, .wim) ou recovery (LZMS solide, .esd) ;
      9. média d'installation (autounattend.xml réglé, install.wim découpé en .swm
         s'il dépasse 4 Go pour une clé FAT32) et MESURE : l'image est appliquée
         en CompactOS dans un disque virtuel et la place occupée est lue (jamais
         estimée). La taille finale installée est mesurée sur la machine par
         C:\Rago\bin\rago-report.ps1.
    Rapport : <OutputDir>\m5-build-report.json. Journal : <WorkDir>\logs\.

    Ne touche JAMAIS à : Secure Boot, TPM, VBS, HVCI, IOMMU, Defender, pare-feu,
    liste de blocage des pilotes vulnérables. Aucune dissimulation : l'état réel
    de la sécurité est mesuré et renvoyé à Linux.

    Windows PowerShell 5.1 (celui de Windows), en administrateur, sur Windows 10
    ou 11 x64 avec au moins 40 Go libres dans -WorkDir.

.PARAMETER SourcePath
    ISO Windows 11 du joueur, dossier de média (contenant sources\install.wim ou
    install.esd), ou fichier install.wim / install.esd.
.PARAMETER Edition
    EditionId à prendre (Professional, Core, Enterprise, IoTEnterprise,
    EnterpriseS, IoTEnterpriseS...). Défaut : Professional (base décidée) ;
    toute autre édition est signalée dans le rapport.
.PARAMETER AllowOlderBuild
    Accepte une build sous 26200 (avant 25H2), pour un essai : Vanguard
    On-Demand n'y est pas possible.
.PARAMETER Index
    Index de l'image dans le fichier (remplace -Edition).
.PARAMETER PlanOnly
    N'écrit rien dans l'image : la monte en lecture seule et écrit ce qui serait
    retiré (<OutputDir>\m5-plan-report.json).
.PARAMETER FinalCompression
    max (LZX, install.wim, montable, défaut) ou recovery (LZMS solide,
    install.esd, plus petit, non montable).
.PARAMETER UpdatePath
    Dossier des mises à jour cumulatives (.msu / .cab) à intégrer à l'image.
    EXIGÉ à chaque reconstruction (décision du 14/11) : Windows Update est
    coupé au runtime, l'image n'a que les correctifs qu'on lui donne ici.
    Sans lui, la construction continue avec un avertissement. Les .msu à la
    racine du dossier (pas de sous-dossier) : la mise à jour cumulative de
    Windows la plus récente est passée à DISM, qui prend les « checkpoint »
    dont il a besoin dans le même dossier ; celle de .NET (nom avec « ndp »)
    est appliquée après .NET 3.5 (ordre documenté par Microsoft).
.PARAMETER AgentPath
    Dossier de l'agent de la bibliothèque partagée (M7), copié dans
    C:\Rago\agent (défaut : windows\rago-agent du dépôt).
.PARAMETER Hibernation
    off (défaut, décision du 14/11 : le micro-Windows est sans état, il ne
    s'hiberne jamais lui-même ; l'hibernation du switch est celle de Linux, M6)
    ou full (essai : hiberfil.sys prend ~40 % de la RAM sur le disque).
.PARAMETER PageFileMB
    Fichier d'échange de taille fixe (défaut 1024 Mio).
.PARAMETER InstallToDisk
    Avec -InstallToPartition : Setup installe sur ce disque / cette partition
    (numéros de Windows Setup, disque à partir de 0, partition à partir de 1) au
    lieu de demander. La partition doit exister ; rien n'est effacé. À n'utiliser
    que si les numéros ont été vérifiés dans Setup (Maj+F10, diskpart).
.EXAMPLE
    .\compile_micro_engine.ps1 -SourcePath D:\Iso\Win11_25H2_French_x64.iso -PlanOnly
.EXAMPLE
    .\compile_micro_engine.ps1 -SourcePath D:\Iso\Win11_25H2_French_x64.iso -UpdatePath D:\MisesAJour -DriverPath D:\Pilotes -RedistPath D:\Redist
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [string]$Edition,
    [int]$Index = 0,
    [string]$WorkDir = (Join-Path $env:SystemDrive 'RagoBuild'),
    [string]$OutputDir,
    [string]$PlanPath = (Join-Path $PSScriptRoot 'micro_engine_plan.json'),
    [string]$UnattendPath = (Join-Path $PSScriptRoot 'autounattend.xml'),
    [string]$PayloadPath = (Join-Path $PSScriptRoot 'rago'),
    [string]$AgentPath = (Join-Path $PSScriptRoot 'rago-agent'),
    [string]$UpdatePath,
    [string]$DriverPath,
    [string]$RedistPath,
    [switch]$NoNetFx3,
    [ValidateSet('max', 'recovery')][string]$FinalCompression = 'max',
    [ValidateRange(256, 65536)][int]$PageFileMB = 1024,
    [ValidateSet('off', 'full')][string]$Hibernation = 'off',
    [string]$PlayerName = 'RagoPlayer',
    [string]$ComputerName = 'RAGO-ENGINE',
    [string]$UILanguage,
    [string]$InputLocale,
    [string]$TimeZone,
    [int]$InstallToDisk = -1,
    [int]$InstallToPartition = -1,
    [string]$ShellCommand = 'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Maximized -File "C:\Rago\bin\rago-shell.ps1"',
    [switch]$SkipMeasure,
    [switch]$MakeIso,
    [switch]$PlanOnly,
    [switch]$AllowUnknownEdition,
    [switch]$AllowOlderBuild
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Base décidée le 14/11 (Sofiene) : Windows 11 Pro 25H2 ou plus. Les autres
# éditions ne sont prises que sur demande explicite (-Edition / -Index).
$EditionPreference = @('Professional')
$KnownEditions = @('Core', 'CoreN', 'Professional', 'ProfessionalN', 'ProfessionalWorkstation', 'Education',
    'Enterprise', 'EnterpriseN', 'IoTEnterprise', 'EnterpriseS', 'EnterpriseSN', 'IoTEnterpriseS', 'IoTEnterpriseSK')
$VanguardOnDemandMinBuild = 26200   # Windows 11 25H2 (Riot, Vanguard Pre-Check, juin 2026)
$Fat32MaxBytes = 4294967295

$t0 = Get-Date
$stamp = $t0.ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$report = [ordered]@{
    schema = 1; kind = 'rago-m5-build-report'; started_at = $t0.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    mode = $(if ($PlanOnly) { 'plan-only' } else { 'build' })
    source = $null; image = $null; parameters = $null; steps = [ordered]@{}; sizes = [ordered]@{}; measure = $null
    warnings = @(); errors = @()
}

function Say { param([string]$Text); Write-Host ('==> ' + $Text) -ForegroundColor Green }
function Warn {
    param([string]$Text)
    Write-Host ('!!  ' + $Text) -ForegroundColor Yellow
    $script:report.warnings += $Text
}
function Mib { param([double]$Bytes); return [math]::Round($Bytes / 1048576, 1) }
function Test-Like {
    param([string]$Name, $Patterns)
    foreach ($p in @($Patterns)) { if ($p -and $Name -like $p) { return $true } }
    return $false
}

# --- 0. vérifications --------------------------------------------------------------------------
if ($env:OS -ne 'Windows_NT') { throw 'compile_micro_engine.ps1 tourne sous Windows (DISM)' }
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'à lancer dans un PowerShell « Exécuter en tant qu''administrateur »' }
if ($PSVersionTable.PSVersion.Major -lt 5) { throw 'Windows PowerShell 5.1 requis' }
if (-not (Get-Command Mount-WindowsImage -ErrorAction SilentlyContinue)) { throw 'module DISM introuvable' }

if (-not (Test-Path -LiteralPath $SourcePath)) {
    throw ('source introuvable : {0}. Rago ne fournit pas Windows : télécharge toi-même l''ISO Windows 11 chez Microsoft (licence à toi).' -f $SourcePath)
}
foreach ($f in @($PlanPath, $UnattendPath, (Join-Path $PayloadPath 'bin\rago-security.ps1'), (Join-Path $PayloadPath 'setup\firstboot.ps1'),
        (Join-Path $PayloadPath 'setup\SetupComplete.cmd'), (Join-Path $PayloadPath 'tasks\rago-boot.xml'),
        (Join-Path $AgentPath 'rago-agent.ps1'), (Join-Path $AgentPath 'launchers.json'))) {
    if (-not (Test-Path -LiteralPath $f)) { throw ('fichier du dépôt manquant : ' + $f) }
}
if ($PlayerName -notmatch '^[A-Za-z0-9][A-Za-z0-9 ._-]{0,19}$' -or $PlayerName.EndsWith('.')) { throw '-PlayerName : 1 à 20 caractères (lettres, chiffres, espace . _ -)' }
if ($ComputerName -notmatch '^[A-Za-z0-9-]{1,15}$' -or $ComputerName -match '^[0-9]+$') { throw '-ComputerName : 1 à 15 caractères A-Z 0-9 -, pas que des chiffres' }
if (($InstallToDisk -ge 0) -ne ($InstallToPartition -ge 1)) { throw '-InstallToDisk et -InstallToPartition vont ensemble (disque >= 0, partition >= 1)' }
if (-not $TimeZone) { $TimeZone = (Get-TimeZone).Id }
[void][System.TimeZoneInfo]::FindSystemTimeZoneById($TimeZone)

if (-not $OutputDir) { $OutputDir = Join-Path $WorkDir 'out' }
$Mount = Join-Path $WorkDir 'mount'
$Scratch = Join-Path $WorkDir 'scratch'
$LogDir = Join-Path $WorkDir 'logs'
$WorkWim = Join-Path $WorkDir 'work.wim'
foreach ($d in @($WorkDir, $OutputDir, $Mount, $Scratch, $LogDir)) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
# Chemins absolus : les méthodes .NET (XmlDocument.Load, File.WriteAllText) ne
# connaissent pas le dossier courant de PowerShell.
$WorkDir = (Resolve-Path -LiteralPath $WorkDir).Path
$OutputDir = (Resolve-Path -LiteralPath $OutputDir).Path
$Mount = Join-Path $WorkDir 'mount'
$Scratch = Join-Path $WorkDir 'scratch'
$LogDir = Join-Path $WorkDir 'logs'
$WorkWim = Join-Path $WorkDir 'work.wim'
$PlanPath = (Resolve-Path -LiteralPath $PlanPath).Path
$UnattendPath = (Resolve-Path -LiteralPath $UnattendPath).Path
$PayloadPath = (Resolve-Path -LiteralPath $PayloadPath).Path
$AgentPath = (Resolve-Path -LiteralPath $AgentPath).Path
foreach ($opt in @('UpdatePath', 'DriverPath', 'RedistPath')) {
    $v = Get-Variable -Name $opt -ValueOnly
    if ($v) {
        if (-not (Test-Path -LiteralPath $v -PathType Container)) { throw ('-{0} : dossier introuvable ({1})' -f $opt, $v) }
        Set-Variable -Name $opt -Value (Resolve-Path -LiteralPath $v).Path
    }
}
if (-not $UpdatePath -and -not $PlanOnly) {
    Warn 'pas de -UpdatePath : image sans les correctifs du mois, et Windows Update est coupé au runtime (décision du 14/11). Passe les cumulatifs courants à chaque reconstruction.'
}
$DismLog = Join-Path $LogDir ('dism-{0}.log' -f $stamp)
$DismExe = Join-Path $env:SystemRoot 'System32\dism.exe'

$drive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID = '{0}'" -f ((Resolve-Path -LiteralPath $WorkDir).Path.Substring(0, 2)))
if ($drive.FileSystem -ne 'NTFS') { throw ('-WorkDir doit être sur un disque NTFS (trouvé : {0})' -f $drive.FileSystem) }
if ($drive.FreeSpace -lt 42949672960) { Warn ('{0} Go libres sur {1} : 40 Go conseillés' -f [math]::Round($drive.FreeSpace / 1073741824, 1), $drive.DeviceID) }

# Plan : refuse tout ce qui toucherait à la sécurité.
$plan = [System.IO.File]::ReadAllText($PlanPath) | ConvertFrom-Json
if ($plan.schema -ne 1) { throw 'micro_engine_plan.json : schema 1 attendu' }
$protected = @($plan.services.never_touch)
foreach ($s in @($plan.services.disable)) {
    if (Test-Like $s.name $protected) { throw ('plan refusé : le service {0} est protégé (never_touch)' -f $s.name) }
}
$baselineWanted = @(
    @{ path = '{CS}\Control\DeviceGuard'; name = 'EnableVirtualizationBasedSecurity'; value = 1 },
    @{ path = '{CS}\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'; name = 'Enabled'; value = 1 },
    @{ path = '{CS}\Control\CI\Config'; name = 'VulnerableDriverBlocklistEnable'; value = 1 }
)
foreach ($b in $baselineWanted) {
    $hit = @($plan.registry.set | Where-Object { $_.hive -eq 'SYSTEM' -and $_.path -eq $b.path -and $_.name -eq $b.name -and [int]$_.value -eq $b.value })
    if ($hit.Count -ne 1) { throw ('plan refusé : base de sécurité absente ({0}\{1} = {2})' -f $b.path, $b.name, $b.value) }
}
foreach ($e in @($plan.registry.set) + @($plan.registry.delete)) {
    if ($e.path -like '*Windows Defender*' -or $e.path -like '*\Services\*' -or ($e.path -like '*DeviceGuard*' -and $e.name -like 'Disable*') -or $e.path -like '*KernelShadowStacks*') {
        throw ('plan refusé : {0}\{1} touche à la sécurité ou aux services (les services passent par services.disable)' -f $e.path, $e.name)
    }
}
$planHash = (Get-FileHash -LiteralPath $PlanPath -Algorithm SHA256).Hash.ToLowerInvariant()

$isoMounted = $null
$hivesLoaded = @()
$mounted = $false
$saved = $false
$measureDisk = $null

function Invoke-Dism {
    param([string[]]$Arguments)
    Write-Verbose ('dism ' + ($Arguments -join ' '))
    $out = & $script:DismExe @Arguments ('/LogPath:' + $script:DismLog) 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw ('dism {0} -> code {1} : {2}' -f ($Arguments -join ' '), $code, (($out | Select-Object -Last 5) -join ' / ')) }
    return $out
}
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments, [int[]]$OkCodes = @(0))
    $out = & $Exe @Arguments 2>&1
    $code = $LASTEXITCODE
    if ($OkCodes -notcontains $code) { throw ('{0} {1} -> code {2} : {3}' -f $Exe, ($Arguments -join ' '), $code, (($out | Out-String).Trim())) }
    return $out
}

function Get-RagoInventory {
    param([string]$Path)
    $inv = [ordered]@{ appx = $null; capabilities_installed = $null; features_enabled = $null; third_party_drivers = $null }
    try { $inv.appx = @(Get-AppxProvisionedPackage -Path $Path).Count } catch { $inv.appx = 'erreur : ' + $_.Exception.Message }
    try { $inv.capabilities_installed = @(Get-WindowsCapability -Path $Path | Where-Object { [string]$_.State -eq 'Installed' }).Count } catch { $inv.capabilities_installed = 'erreur : ' + $_.Exception.Message }
    try { $inv.features_enabled = @(Get-WindowsOptionalFeature -Path $Path | Where-Object { [string]$_.State -eq 'Enabled' }).Count } catch { $inv.features_enabled = 'erreur : ' + $_.Exception.Message }
    try { $inv.third_party_drivers = @(Get-WindowsDriver -Path $Path).Count } catch { $inv.third_party_drivers = 'erreur : ' + $_.Exception.Message }
    return $inv
}

# --- ruches hors ligne ----------------------------------------------------------------------------
function Mount-RagoHive {
    param([string]$Name, [string]$File)
    Invoke-Native (Join-Path $env:SystemRoot 'System32\reg.exe') @('load', ('HKLM\' + $Name), $File) | Out-Null
    $script:hivesLoaded += $Name
}
function Dismount-RagoHives {
    foreach ($h in @($script:hivesLoaded)) {
        $ok = $false
        for ($i = 0; $i -lt 10 -and -not $ok; $i++) {
            [gc]::Collect(); [gc]::WaitForPendingFinalizers()
            & (Join-Path $env:SystemRoot 'System32\reg.exe') unload ('HKLM\' + $h) 2>&1 | Out-Null
            $ok = ($LASTEXITCODE -eq 0)
            if (-not $ok) { Start-Sleep -Seconds 1 }
        }
        if (-not $ok) { Write-Host ('!!  ruche HKLM\{0} pas déchargée : reg unload HKLM\{0} à la main avant tout' -f $h) -ForegroundColor Red }
    }
    $script:hivesLoaded = @()
}
function Get-RagoHiveKey {
    param([string]$Hive, [string]$Path, [string]$ControlSet)
    return ('RAGO_{0}\{1}' -f $Hive, ($Path -replace '\{CS\}', $ControlSet))
}
function Set-RagoOfflineValue {
    param([string]$SubKey, [string]$Name, [string]$Type, $Value)
    $kind = [Microsoft.Win32.RegistryValueKind]$Type
    switch ($Type) {
        'DWord' { $v = [int]$Value }
        'QWord' { $v = [long]$Value }
        'MultiString' { $v = [string[]]@($Value) }
        default { $v = [string]$Value }
    }
    $k = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey($SubKey)
    try { $k.SetValue($Name, $v, $kind) } finally { $k.Close() }
}
function Get-RagoOfflineValue {
    param([string]$SubKey, [string]$Name)
    $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($SubKey)
    if ($null -eq $k) { return $null }
    try { return $k.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } finally { $k.Close() }
}
function Remove-RagoOfflineValue {
    param([string]$SubKey, [string]$Name)
    $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($SubKey, $true)
    if ($null -eq $k) { return $false }
    try {
        if ($null -eq $k.GetValue($Name, $null)) { return $false }
        $k.DeleteValue($Name, $false); return $true
    } finally { $k.Close() }
}

function Remove-RagoPath {
    param([string]$Path)
    # Fichiers de l'image : propriétaire TrustedInstaller. icacls (options non
    # traduites, contrairement à takeown /D) donne la main aux Administrateurs.
    try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop; return }
    catch {
        $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
        & $icacls $Path /setowner '*S-1-5-32-544' /T /C /L /Q 2>&1 | Out-Null
        & $icacls $Path /grant '*S-1-5-32-544:F' /T /C /L /Q 2>&1 | Out-Null
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    }
}

function Get-RagoFolderBytes {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $sum = 0.0
    Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object { $sum += $_.Length }
    return $sum
}

# --- autounattend.xml ---------------------------------------------------------------------------
function New-RagoUnattend {
    param([string]$Template, [string]$Destination, [string]$Language, [string]$Keyboard)
    $x = New-Object System.Xml.XmlDocument
    $x.PreserveWhitespace = $true
    $x.Load($Template)
    $ns = New-Object System.Xml.XmlNamespaceManager($x.NameTable)
    $ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
    function SetAll([string]$XPath, [string]$Value, [int]$Expect) {
        $nodes = $x.SelectNodes($XPath, $ns)
        if ($nodes.Count -ne $Expect) { throw ('autounattend.xml : {0} trouvé {1} fois, {2} attendu' -f $XPath, $nodes.Count, $Expect) }
        foreach ($n in $nodes) { $n.InnerText = $Value }
    }
    $pe = "//u:settings[@pass='windowsPE']/u:component[@name='Microsoft-Windows-International-Core-WinPE']"
    $oobeIntl = "//u:settings[@pass='oobeSystem']/u:component[@name='Microsoft-Windows-International-Core']"
    SetAll "$pe/u:SetupUILanguage/u:UILanguage" $Language 1
    foreach ($c in @($pe, $oobeIntl)) {
        SetAll "$c/u:InputLocale" $Keyboard 1
        SetAll "$c/u:SystemLocale" $Language 1
        SetAll "$c/u:UILanguage" $Language 1
        SetAll "$c/u:UserLocale" $Language 1
    }
    $spec = "//u:settings[@pass='specialize']/u:component[@name='Microsoft-Windows-Shell-Setup']"
    SetAll "$spec/u:ComputerName" $ComputerName 1
    SetAll "$spec/u:TimeZone" $TimeZone 1
    $shell = "//u:settings[@pass='oobeSystem']/u:component[@name='Microsoft-Windows-Shell-Setup']"
    SetAll "$shell/u:UserAccounts/u:LocalAccounts/u:LocalAccount/u:Name" $PlayerName 1
    SetAll "$shell/u:AutoLogon/u:Username" $PlayerName 1
    if ($InstallToDisk -ge 0) {
        $os = $x.SelectSingleNode("//u:settings[@pass='windowsPE']/u:component[@name='Microsoft-Windows-Setup']/u:ImageInstall/u:OSImage", $ns)
        $uri = 'urn:schemas-microsoft-com:unattend'
        $to = $x.CreateElement('InstallTo', $uri)
        $d = $x.CreateElement('DiskID', $uri); $d.InnerText = [string]$InstallToDisk; [void]$to.AppendChild($d)
        $p = $x.CreateElement('PartitionID', $uri); $p.InnerText = [string]$InstallToPartition; [void]$to.AppendChild($p)
        [void]$os.InsertAfter($to, $os.SelectSingleNode('u:InstallFrom', $ns))
    }
    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
    $w = [System.Xml.XmlWriter]::Create($Destination, $settings)
    try { $x.Save($w) } finally { $w.Close() }
}

Start-Transcript -Path (Join-Path $LogDir ('compile-{0}.log' -f $stamp)) | Out-Null
try {
    # --- 1. source et choix de l'image ---------------------------------------------------------------
    Say 'source fournie par le joueur (BYOL)'
    $media = $null
    $src = (Resolve-Path -LiteralPath $SourcePath).Path
    if ($src -like '*.iso') {
        $di = Get-DiskImage -ImagePath $src
        if (-not $di.Attached) { $di = Mount-DiskImage -ImagePath $src -PassThru; $isoMounted = $src }
        $letter = ($di | Get-Volume).DriveLetter
        if (-not $letter) { throw 'ISO montée sans lettre de lecteur' }
        $media = '{0}:\' -f $letter
    } elseif ((Get-Item -LiteralPath $src).PSIsContainer) {
        $media = $src
    }
    if ($null -ne $media) {
        $imageFile = @('install.wim', 'install.esd') | ForEach-Object { Join-Path $media ('sources\' + $_) } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $imageFile) {
            if (Test-Path -LiteralPath (Join-Path $media 'sources\install.swm')) { throw 'média avec install.swm (découpé) : donne plutôt l''ISO d''origine' }
            throw ('pas de sources\install.wim ni install.esd dans {0}' -f $media)
        }
    } else {
        $imageFile = $src
        if ($imageFile -notlike '*.wim' -and $imageFile -notlike '*.esd') { throw '-SourcePath : .iso, dossier de média, .wim ou .esd' }
        Warn 'image seule (pas de média) : pas de .NET 3.5 depuis sources\sxs, pas de média d''installation, seulement install.wim / install.esd'
    }
    $report.source = [ordered]@{ type = $(if ($src -like '*.iso') { 'iso' } elseif ($media) { 'media' } else { 'image' }); file = (Split-Path -Leaf $src); image_file = (Split-Path -Leaf $imageFile) }

    $images = @(Get-WindowsImage -ImagePath $imageFile | ForEach-Object { Get-WindowsImage -ImagePath $imageFile -Index $_.ImageIndex })
    foreach ($i in $images) { Write-Host ('    index {0} : {1} ({2}, {3})' -f $i.ImageIndex, $i.ImageName, $i.EditionId, $i.Version) }
    $chosen = $null
    if ($Index -gt 0) { $chosen = $images | Where-Object { $_.ImageIndex -eq $Index } | Select-Object -First 1 }
    elseif ($Edition) { $chosen = $images | Where-Object { $_.EditionId -eq $Edition } | Select-Object -First 1 }
    else {
        foreach ($e in $EditionPreference) {
            if ($null -eq $chosen) { $chosen = $images | Where-Object { $_.EditionId -eq $e } | Select-Object -First 1 }
        }
    }
    if ($null -eq $chosen) {
        if (-not $Edition -and $Index -le 0) { throw ('pas d''édition Professional dans {0} (base Rago : Windows 11 Pro 25H2 ou plus) : prends l''ISO Windows 11 de Microsoft, ou donne -Edition / -Index (voir la liste ci-dessus)' -f (Split-Path -Leaf $imageFile)) }
        throw ('édition introuvable dans {0} : donne -Edition ou -Index (voir la liste ci-dessus)' -f (Split-Path -Leaf $imageFile))
    }
    $ver = [version]$chosen.Version
    $langs = @($chosen.Languages)
    $defLang = $langs[0]
    if ($chosen.PSObject.Properties.Name -contains 'DefaultLanguageIndex' -and $null -ne $chosen.DefaultLanguageIndex -and $chosen.DefaultLanguageIndex -lt $langs.Count) { $defLang = $langs[$chosen.DefaultLanguageIndex] }
    $report.image = [ordered]@{ index = $chosen.ImageIndex; name = $chosen.ImageName; edition = $chosen.EditionId; version = $chosen.Version; build = $ver.Build; languages = $langs; default_language = $defLang; architecture = $chosen.Architecture }
    Say ('image : {0} ({1}, build {2}, {3})' -f $chosen.ImageName, $chosen.EditionId, $ver.Build, $defLang)

    $arch = [string]$chosen.Architecture
    if ($arch -ne '9' -and $arch -notmatch '^(x64|amd64)$') { throw ('image non x64 (architecture DISM {0})' -f $arch) }
    if ($ver.Build -lt 22000) { throw ('build {0} : ce n''est pas Windows 11' -f $ver.Build) }
    if ($ver.Build -lt $VanguardOnDemandMinBuild) {
        if (-not $AllowOlderBuild) { throw ('build {0} < {1} : la base Rago est Windows 11 25H2 ou plus (minimum de Vanguard On-Demand). Prends une ISO plus récente, ou -AllowOlderBuild pour un essai' -f $ver.Build, $VanguardOnDemandMinBuild) }
        Warn ('build {0} < {1} (-AllowOlderBuild) : pas de Vanguard On-Demand (Riot, Pre-Check : Windows 11 25H2 ou plus) ; Vanguard classique (au démarrage) reste possible' -f $ver.Build, $VanguardOnDemandMinBuild)
    }
    if ($chosen.EditionId -ne 'Professional') { Warn ('édition {0} : la base décidée est Windows 11 Pro (Professional)' -f $chosen.EditionId) }
    if ($KnownEditions -notcontains $chosen.EditionId) {
        if (-not $AllowUnknownEdition) { throw ('édition {0} non prévue (ajoute -AllowUnknownEdition pour essayer quand même)' -f $chosen.EditionId) }
        Warn ('édition {0} non prévue : essai' -f $chosen.EditionId)
    }
    if ($chosen.EditionId -like 'IoT*' -or $chosen.EditionId -like 'EnterpriseS*') {
        Warn ('{0} : licence IoT / LTSC prévue pour des appareils à usage fixe (doc Microsoft), et League of Legends refuse les éditions Enterprise : vérifie que ta licence couvre ce PC de jeu' -f $chosen.EditionId)
    }
    $dismBuild = (Get-Item -LiteralPath $DismExe).VersionInfo.FileBuildPart
    if ($dismBuild -lt $ver.Build) { Warn ('DISM de ce Windows (build {0}) plus ancien que l''image ({1}) : en cas d''erreur, installe le DISM de l''ADK Windows récent' -f $dismBuild, $ver.Build) }

    if (-not $UILanguage) { $UILanguage = $defLang }
    if (-not $InputLocale) { $InputLocale = $UILanguage }
    $report.parameters = [ordered]@{
        final_compression = $FinalCompression; hibernation = $Hibernation; pagefile_mb = $PageFileMB; player = $PlayerName
        computer_name = $ComputerName; ui_language = $UILanguage; input_locale = $InputLocale; time_zone = $TimeZone
        install_to = $(if ($InstallToDisk -ge 0) { '{0}/{1}' -f $InstallToDisk, $InstallToPartition } else { 'demandé par Setup' })
        net_fx3 = (-not $NoNetFx3); updates = [bool]$UpdatePath; drivers = [bool]$DriverPath; redist = [bool]$RedistPath
        plan_sha256 = $planHash; shell = $ShellCommand
    }

    # --- 1 bis. image de travail ---------------------------------------------------------------------
    $stale = @(Get-WindowsImage -Mounted | Where-Object { $_.Path -eq $Mount })
    if ($stale.Count -gt 0) { Warn 'image déjà montée dans le dossier de travail (essai précédent) : démontée sans sauvegarde'; Dismount-WindowsImage -Path $Mount -Discard | Out-Null }
    if (Test-Path -LiteralPath $WorkWim) { Remove-Item -LiteralPath $WorkWim -Force }
    Say ('export de l''index {0} dans l''image de travail' -f $chosen.ImageIndex)
    Invoke-Dism @('/Export-Image', ('/SourceImageFile:' + $imageFile), ('/SourceIndex:' + $chosen.ImageIndex), ('/DestinationImageFile:' + $WorkWim), '/Compress:max', '/CheckIntegrity') | Out-Null
    $report.sizes.source_index_exported_mib = Mib (Get-Item -LiteralPath $WorkWim).Length
    Say 'montage'
    if ($PlanOnly) { Mount-WindowsImage -ImagePath $WorkWim -Index 1 -Path $Mount -ReadOnly -ScratchDirectory $Scratch -LogPath $DismLog | Out-Null }
    else { Mount-WindowsImage -ImagePath $WorkWim -Index 1 -Path $Mount -ScratchDirectory $Scratch -LogPath $DismLog | Out-Null }
    $mounted = $true
    $report.steps.inventory_before = Get-RagoInventory $Mount

    # Ordre de Microsoft (« Update Windows installation media with Dynamic
    # Update ») : mise à jour cumulative, nettoyage, .NET 3.5, puis la mise à
    # jour cumulative de .NET (fichier « ndp » du catalogue), ici à l'étape 7.
    # Windows 11 24H2 et plus : on passe à DISM le FICHIER de la mise à jour
    # cumulative la plus récente (numéro KB le plus haut) ; DISM prend dans le
    # même dossier les mises à jour « checkpoint » dont il a besoin (pages
    # Microsoft « checkpoint cumulative updates »). Jamais le dossier entier :
    # DISM ajouterait chaque .msu à part (checkpoint déjà intégrée → échec) et
    # fouillerait les sous-dossiers (le .NET partirait trop tôt).
    $dotnetUpdates = @()
    if ($UpdatePath -and -not $PlanOnly) {
        $all = @(Get-ChildItem -LiteralPath $UpdatePath -File -Recurse | Where-Object { $_.Extension -in '.msu', '.cab' })
        $nested = @($all | Where-Object { $_.DirectoryName.TrimEnd('\') -ne $UpdatePath.TrimEnd('\') })
        if ($nested.Count -gt 0) {
            throw ('-UpdatePath : .msu / .cab dans des sous-dossiers ({0}) : mets-les tous à la racine du dossier' -f (($nested | ForEach-Object { $_.FullName }) -join ', '))
        }
        $dotnetUpdates = @($all | Where-Object { $_.Name -like '*ndp*' } | Sort-Object Name)
        $osMsu = @($all | Where-Object { $_.Name -notlike '*ndp*' -and $_.Extension -eq '.msu' })
        $osCab = @($all | Where-Object { $_.Name -notlike '*ndp*' -and $_.Extension -eq '.cab' } | Sort-Object Name)
        $target = $null
        if ($osMsu.Count -gt 0) {
            # Numéro KB le plus haut ; sans numéro lisible, le plus gros fichier.
            $kbOf = { param($f) if ($f.Name -match '(?i)kb(\d+)') { return [int64]$Matches[1] } else { return [int64](-1) } }
            $cands = @($osMsu | ForEach-Object { [pscustomobject]@{ File = $_; Kb = (& $kbOf $_); Size = $_.Length } })
            $target = ($cands | Sort-Object Kb, Size | Select-Object -Last 1).File
        }
        $report.steps.updates = [ordered]@{
            target = $(if ($target) { $target.Name } else { $null })
            other_msu_in_folder = @($osMsu | Where-Object { $_.FullName -ne $(if ($target) { $target.FullName } else { '' }) } | ForEach-Object { $_.Name })
            cab_applied = @(); cab_failed = @()
            dotnet = @($dotnetUpdates | ForEach-Object { $_.Name }); dotnet_applied = @(); dotnet_failed = @()
        }
        if ($all.Count -eq 0) { Warn ('-UpdatePath : aucun .msu / .cab dans {0}' -f $UpdatePath) }
        foreach ($c in $osCab) {
            Say ('paquet du joueur : {0}' -f $c.Name)
            try {
                Add-WindowsPackage -Path $Mount -PackagePath $c.FullName -ScratchDirectory $Scratch -LogPath $DismLog | Out-Null
                $report.steps.updates.cab_applied += $c.Name
            } catch {
                $report.steps.updates.cab_failed += ('{0} : {1}' -f $c.Name, $_.Exception.Message)
                Warn ('paquet {0} : {1}' -f $c.Name, $_.Exception.Message)
            }
        }
        if ($target) {
            Say ('mise à jour cumulative de Windows : {0} (checkpoint prises par DISM dans le même dossier)' -f $target.Name)
            Add-WindowsPackage -Path $Mount -PackagePath $target.FullName -ScratchDirectory $Scratch -LogPath $DismLog | Out-Null
        } elseif ($all.Count -gt 0) {
            Warn '-UpdatePath : pas de mise à jour cumulative de Windows (.msu sans « ndp »)'
        }
    }

    # --- 2. Appx ---------------------------------------------------------------------------------------
    Say 'étape 1 : paquets Appx provisionnés'
    $st = [ordered]@{ removed = @(); kept = @(); failed = @() }
    foreach ($a in @(Get-AppxProvisionedPackage -Path $Mount)) {
        if (Test-Like $a.DisplayName $plan.appx.keep) { $st.kept += $a.DisplayName; continue }
        if (-not (Test-Like $a.DisplayName $plan.appx.remove)) { $st.kept += $a.DisplayName; continue }
        if ($PlanOnly) { $st.removed += $a.DisplayName; continue }
        try { Remove-AppxProvisionedPackage -Path $Mount -PackageName $a.PackageName -LogPath $DismLog | Out-Null; $st.removed += $a.DisplayName }
        catch { $st.failed += ('{0} : {1}' -f $a.DisplayName, $_.Exception.Message) }
    }
    $report.steps.appx = $st

    # --- 3. fonctions à la demande, fonctionnalités ------------------------------------------------------
    Say 'étape 2 : fonctions à la demande et langues en trop'
    $st = [ordered]@{ removed = @(); kept = @(); failed = @() }
    foreach ($c in @(Get-WindowsCapability -Path $Mount | Where-Object { [string]$_.State -eq 'Installed' })) {
        $n = $c.Name
        $parts = $n -split '~'
        $capLang = $(if ($parts.Count -ge 4) { $parts[3] } else { '' })
        $remove = $false
        if (Test-Like $n $plan.capabilities.keep) { $remove = $false }
        elseif (Test-Like $n $plan.capabilities.remove) { $remove = $true }
        elseif ((Test-Like $n $plan.capabilities.remove_other_languages) -and $capLang -and $capLang -ne $UILanguage -and $capLang -ne $defLang) { $remove = $true }
        if (-not $remove) { $st.kept += $n; continue }
        if ($PlanOnly) { $st.removed += $n; continue }
        try { Remove-WindowsCapability -Path $Mount -Name $n -LogPath $DismLog | Out-Null; $st.removed += $n }
        catch { $st.failed += ('{0} : {1}' -f $n, $_.Exception.Message) }
    }
    $report.steps.capabilities = $st

    Say 'étape 2 bis : packs de langue en trop'
    $st = [ordered]@{ removed = @(); failed = @() }
    foreach ($pk in @(Get-WindowsPackage -Path $Mount | Where-Object { Test-Like $_.PackageName $plan.capabilities.language_packs_other })) {
        $parts = $pk.PackageName -split '~'
        $pkLang = $(if ($parts.Count -ge 4) { $parts[3] } else { '' })
        if (-not $pkLang -or $pkLang -eq $UILanguage -or $pkLang -eq $defLang) { continue }
        if ($PlanOnly) { $st.removed += $pk.PackageName; continue }
        try { Remove-WindowsPackage -Path $Mount -PackageName $pk.PackageName -NoRestart -LogPath $DismLog | Out-Null; $st.removed += $pk.PackageName }
        catch { $st.failed += ('{0} : {1}' -f $pk.PackageName, $_.Exception.Message) }
    }
    $report.steps.language_packs = $st

    Say 'étape 2 ter : fonctionnalités facultatives'
    $st = [ordered]@{ disabled = @(); failed = @() }
    foreach ($f in @(Get-WindowsOptionalFeature -Path $Mount | Where-Object { [string]$_.State -eq 'Enabled' })) {
        $n = $f.FeatureName
        if ((Test-Like $n $plan.features.keep) -or -not (Test-Like $n $plan.features.disable)) { continue }
        if ($PlanOnly) { $st.disabled += $n; continue }
        try { Disable-WindowsOptionalFeature -Path $Mount -FeatureName $n -NoRestart -LogPath $DismLog | Out-Null; $st.disabled += $n }
        catch { $st.failed += ('{0} : {1}' -f $n, $_.Exception.Message) }
    }
    $report.steps.features = $st

    # --- 4. pilotes -------------------------------------------------------------------------------------
    Say 'étape 4 : pilotes'
    $st = [ordered]@{ removed = @(); added = $null; failed = @(); note = 'pilotes inbox non retirables par DISM (doc Microsoft)' }
    foreach ($d in @(Get-WindowsDriver -Path $Mount)) {
        if ($plan.drivers.keep_classes -contains $d.ClassName) { continue }
        if ($plan.drivers.remove_oem_classes -notcontains $d.ClassName) { continue }
        if ($PlanOnly) { $st.removed += ('{0} ({1})' -f $d.Driver, $d.ClassName); continue }
        try { Remove-WindowsDriver -Path $Mount -Driver $d.Driver -LogPath $DismLog | Out-Null; $st.removed += ('{0} ({1})' -f $d.Driver, $d.ClassName) }
        catch { $st.failed += ('{0} : {1}' -f $d.Driver, $_.Exception.Message) }
    }
    if ($DriverPath -and -not $PlanOnly) {
        $before = @(Get-WindowsDriver -Path $Mount).Count
        Add-WindowsDriver -Path $Mount -Driver $DriverPath -Recurse -LogPath $DismLog | Out-Null
        $st.added = @(Get-WindowsDriver -Path $Mount).Count - $before
    }
    $report.steps.drivers = $st

    if ($PlanOnly) {
        $report.steps.services = 'non lus en mode -PlanOnly (image montée en lecture seule) : liste dans micro_engine_plan.json'
        throw 'RAGO_PLAN_ONLY_DONE'
    }

    # --- 5. ruches hors ligne ---------------------------------------------------------------------------
    Say 'étape 5 : services, sécurité, télémétrie (ruches hors ligne)'
    Mount-RagoHive 'RAGO_SYSTEM' (Join-Path $Mount 'Windows\System32\config\SYSTEM')
    Mount-RagoHive 'RAGO_SOFTWARE' (Join-Path $Mount 'Windows\System32\config\SOFTWARE')
    Mount-RagoHive 'RAGO_DEFAULT' (Join-Path $Mount 'Users\Default\NTUSER.DAT')
    try {
        $cur = Get-RagoOfflineValue 'RAGO_SYSTEM\Select' 'Current'
        if ($null -eq $cur) { throw 'ruche SYSTEM : Select\Current absent' }
        $cs = 'ControlSet{0:D3}' -f [int]$cur
        $st = [ordered]@{ control_set = $cs; services = @(); set = 0; deleted = @(); security_floor = $null }
        foreach ($s in @($plan.services.disable)) {
            $k = 'RAGO_SYSTEM\{0}\Services\{1}' -f $cs, $s.name
            $before = Get-RagoOfflineValue $k 'Start'
            if ($null -eq $before) { $st.services += ('{0} : absent' -f $s.name); continue }
            Set-RagoOfflineValue $k 'Start' 'DWord' 4
            $st.services += ('{0} : Start {1} -> 4' -f $s.name, $before)
        }
        foreach ($e in @($plan.registry.set)) {
            Set-RagoOfflineValue (Get-RagoHiveKey $e.hive $e.path $cs) $e.name $e.type $e.value
            $st.set++
        }
        foreach ($e in @($plan.registry.delete)) {
            if (Remove-RagoOfflineValue (Get-RagoHiveKey $e.hive $e.path $cs) $e.name) { $st.deleted += ('{0}\{1}' -f $e.path, $e.name) }
        }
        # Relecture : la base de sécurité doit être là, les services protégés pas coupés.
        $bad = @()
        foreach ($b in $baselineWanted) {
            $v = Get-RagoOfflineValue (Get-RagoHiveKey 'SYSTEM' $b.path $cs) $b.name
            if ($null -eq $v -or [int]$v -ne $b.value) { $bad += ('{0}\{1} = {2}' -f $b.path, $b.name, $v) }
        }
        foreach ($n in $protected) {
            if ($n -like '*[*?]*') { continue }
            $v = Get-RagoOfflineValue ('RAGO_SYSTEM\{0}\Services\{1}' -f $cs, $n) 'Start'
            if ($null -ne $v -and [int]$v -eq 4) { $bad += ('service protégé {0} désactivé dans l''image source' -f $n) }
        }
        if ($bad.Count -gt 0) { throw ('base de sécurité incorrecte, image refusée : ' + ($bad -join ' ; ')) }
        $st.security_floor = 'VBS + HVCI configurés, liste de blocage des pilotes active, services de sécurité non coupés'
        $report.steps.registry = $st
    } finally {
        Dismount-RagoHives
    }

    # --- 6. charge utile Rago ---------------------------------------------------------------------------
    Say 'étape 6 : charge utile Rago (C:\Rago)'
    $rago = Join-Path $Mount 'Rago'
    if (Test-Path -LiteralPath $rago) { Remove-RagoPath $rago }
    New-Item -ItemType Directory -Path $rago -Force | Out-Null
    foreach ($sub in @('bin', 'setup', 'tasks')) { Copy-Item -LiteralPath (Join-Path $PayloadPath $sub) -Destination $rago -Recurse -Force }
    # Agent de la bibliothèque partagée (M7) : C:\Rago\agent.
    $agentDst = Join-Path $rago 'agent'
    New-Item -ItemType Directory -Path $agentDst -Force | Out-Null
    foreach ($f in @(Get-ChildItem -LiteralPath $AgentPath -File | Where-Object { $_.Extension -in @('.ps1', '.psm1', '.json', '.md') })) {
        Copy-Item -LiteralPath $f.FullName -Destination $agentDst -Force
    }
    if ($RedistPath) { Copy-Item -LiteralPath $RedistPath -Destination (Join-Path $rago 'redist') -Recurse -Force }
    $scripts = Join-Path $Mount 'Windows\Setup\Scripts'
    New-Item -ItemType Directory -Path $scripts -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PayloadPath 'setup\SetupComplete.cmd') -Destination (Join-Path $scripts 'SetupComplete.cmd') -Force
    $info = [ordered]@{
        schema = 1; kind = 'rago-micro-engine'; built_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        builder = 'windows/compile_micro_engine.ps1 (M5)'
        image = [ordered]@{ edition = $chosen.EditionId; name = $chosen.ImageName; version = $chosen.Version; build = $ver.Build; default_language = $defLang }
        player = $PlayerName; shell = $ShellCommand; pagefile_mb = $PageFileMB; hibernation = $Hibernation; compact_os = $true
        final_compression = $FinalCompression; plan_sha256 = $planHash
    }
    [System.IO.File]::WriteAllText((Join-Path $rago 'micro-engine.json'), ($info | ConvertTo-Json -Depth 6) + "`n", (New-Object System.Text.UTF8Encoding($false)))
    # C:\Rago tourne en SYSTEM : écriture réservée à SYSTEM et aux Administrateurs.
    Invoke-Native (Join-Path $env:SystemRoot 'System32\icacls.exe') @($rago, '/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-32-545:(OI)(CI)RX', '/T', '/C', '/Q') | Out-Null
    $report.steps.payload = [ordered]@{ files = @(Get-ChildItem -LiteralPath $rago -Recurse -File | ForEach-Object { $_.FullName.Substring($Mount.Length) }); bytes = (Get-RagoFolderBytes $rago) }

    # --- 7. nettoyage, .NET 3.5, fichiers ---------------------------------------------------------------
    Say 'étape 3 : magasin de composants (StartComponentCleanup + ResetBase)'
    try {
        Invoke-Dism @(('/Image:' + $Mount), '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase', ('/ScratchDir:' + $Scratch)) | Out-Null
        $report.steps.component_cleanup = 'ok'
    } catch {
        $report.steps.component_cleanup = 'erreur : ' + $_.Exception.Message
        Warn ('nettoyage du magasin de composants : ' + $_.Exception.Message)
    }
    if (-not $NoNetFx3) {
        $sxs = $(if ($media) { Join-Path $media 'sources\sxs' } else { $null })
        if ($sxs -and (Test-Path -LiteralPath $sxs)) {
            Say '.NET 3.5 depuis sources\sxs (après le nettoyage : il reste « en attente » jusqu''au premier démarrage)'
            try {
                Enable-WindowsOptionalFeature -Path $Mount -FeatureName NetFx3 -All -Source $sxs -LimitAccess -NoRestart -LogPath $DismLog | Out-Null
                $report.steps.netfx3 = 'ajouté'
            } catch { $report.steps.netfx3 = 'erreur : ' + $_.Exception.Message; Warn ('.NET 3.5 : ' + $_.Exception.Message) }
        } else {
            $report.steps.netfx3 = 'sauté : pas de sources\sxs'
            Warn '.NET 3.5 non ajouté (pas de sources\sxs) : certains vieux jeux / launchers en ont besoin'
        }
    }
    # Mise à jour cumulative de .NET APRÈS .NET 3.5 (sinon .NET 3.5 resterait
    # à la version de l'ISO : Windows Update est coupé au runtime).
    foreach ($f in $dotnetUpdates) {
        Say ('mise à jour cumulative de .NET : {0}' -f $f.Name)
        try {
            Add-WindowsPackage -Path $Mount -PackagePath $f.FullName -ScratchDirectory $Scratch -LogPath $DismLog | Out-Null
            $report.steps.updates.dotnet_applied += $f.Name
        } catch {
            $report.steps.updates.dotnet_failed += ('{0} : {1}' -f $f.Name, $_.Exception.Message)
            Warn ('mise à jour de .NET {0} : {1}' -f $f.Name, $_.Exception.Message)
        }
    }
    Say 'étape 8 : sauvegardes, caches, journaux, WinRE'
    $st = [ordered]@{ removed = @(); failed = @(); bytes = 0 }
    foreach ($rel in @($plan.files_remove.paths)) {
        $full = Join-Path $Mount $rel
        foreach ($item in @(Get-Item -Path $full -Force -ErrorAction SilentlyContinue)) {
            $b = $(if ($item.PSIsContainer) { Get-RagoFolderBytes $item.FullName } else { $item.Length })
            try { Remove-RagoPath $item.FullName; $st.removed += $item.FullName.Substring($Mount.Length); $st.bytes += $b }
            catch { $st.failed += ('{0} : {1}' -f $item.FullName.Substring($Mount.Length), $_.Exception.Message) }
        }
    }
    $report.steps.files = $st
    $report.steps.inventory_after = Get-RagoInventory $Mount

    # --- 8. démontage, export ---------------------------------------------------------------------------
    Say 'démontage (enregistrement)'
    Dismount-WindowsImage -Path $Mount -Save -CheckIntegrity -LogPath $DismLog | Out-Null
    $saved = $true; $mounted = $false
    $report.sizes.work_wim_after_save_mib = Mib (Get-Item -LiteralPath $WorkWim).Length
    $final = $(if ($FinalCompression -eq 'recovery') { Join-Path $OutputDir 'install.esd' } else { Join-Path $OutputDir 'install.wim' })
    foreach ($old in @('install.wim', 'install.esd')) { $p = Join-Path $OutputDir $old; if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force } }
    Say ('export final ({0})' -f $FinalCompression)
    Invoke-Dism @('/Export-Image', ('/SourceImageFile:' + $WorkWim), '/SourceIndex:1', ('/DestinationImageFile:' + $final), ('/Compress:' + $FinalCompression), '/CheckIntegrity') | Out-Null
    $report.sizes.final_image_file = Split-Path -Leaf $final
    $report.sizes.final_image_mib = Mib (Get-Item -LiteralPath $final).Length

    # --- 9. média d'installation ------------------------------------------------------------------------
    $unattendOut = Join-Path $OutputDir 'autounattend.xml'
    New-RagoUnattend -Template $UnattendPath -Destination $unattendOut -Language $UILanguage -Keyboard $InputLocale
    [xml](Get-Content -LiteralPath $unattendOut -Raw -Encoding UTF8) | Out-Null
    if ($media) {
        Say 'média d''installation'
        $mediaOut = Join-Path $OutputDir 'media'
        if (Test-Path -LiteralPath $mediaOut) { Remove-RagoPath $mediaOut }
        # Sans barre finale (robocopy lirait \" comme un guillemet échappé) ; « E:\. » pour la racine d'un lecteur.
        $from = $media.TrimEnd('\')
        if ($from -match '^[A-Za-z]:$') { $from += '\.' }
        Invoke-Native (Join-Path $env:SystemRoot 'System32\robocopy.exe') @($from, $mediaOut, '/E', '/XF', 'install.wim', 'install.esd', 'install*.swm', 'autounattend.xml', '/NFL', '/NDL', '/NJH', '/NJS', '/NP') -OkCodes @(0, 1, 2, 3) | Out-Null
        Get-ChildItem -LiteralPath $mediaOut -Recurse -Force -File | Where-Object { $_.IsReadOnly } | ForEach-Object { $_.IsReadOnly = $false }
        $finalLen = (Get-Item -LiteralPath $final).Length
        if ($finalLen -gt $Fat32MaxBytes -and $FinalCompression -eq 'recovery') {
            Warn ('install.esd de {0} Mio > 4 Go : une clé FAT32 ne le prendra pas (NTFS, ou -FinalCompression max qui se découpe)' -f (Mib $finalLen))
            Copy-Item -LiteralPath $final -Destination (Join-Path $mediaOut 'sources\install.esd') -Force
            $report.sizes.media_image = 'install.esd (> 4 Go)'
        } elseif ($finalLen -gt $Fat32MaxBytes) {
            Say ('{0} Mio > 4 Go : découpé en install*.swm pour une clé FAT32' -f (Mib $finalLen))
            Invoke-Dism @('/Split-Image', ('/ImageFile:' + $final), ('/SWMFile:' + (Join-Path $mediaOut 'sources\install.swm')), '/FileSize:3800', '/CheckIntegrity') | Out-Null
            $report.sizes.media_image = 'install.swm (découpé, 3800 Mio max par morceau)'
        } else {
            Copy-Item -LiteralPath $final -Destination (Join-Path $mediaOut ('sources\' + (Split-Path -Leaf $final))) -Force
            $report.sizes.media_image = Split-Path -Leaf $final
        }
        Copy-Item -LiteralPath $unattendOut -Destination (Join-Path $mediaOut 'autounattend.xml') -Force
        $report.sizes.media_mib = Mib (Get-RagoFolderBytes $mediaOut)
        if ($MakeIso) {
            $oscdimg = Get-ChildItem -Path "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -eq $oscdimg) { Warn '-MakeIso : oscdimg.exe (ADK, outils de déploiement) introuvable : pas d''ISO' }
            else {
                $iso = Join-Path $OutputDir 'rago-micro-windows.iso'
                $boot = '2#p0,e,b{0}#pEF,e,b{1}' -f (Join-Path $mediaOut 'boot\etfsboot.com'), (Join-Path $mediaOut 'efi\microsoft\boot\efisys.bin')
                Invoke-Native $oscdimg.FullName @('-m', '-o', '-u2', '-udfver102', ('-bootdata:' + $boot), $mediaOut, $iso) | Out-Null
                $report.sizes.iso_mib = Mib (Get-Item -LiteralPath $iso).Length
            }
        }
    }

    # --- 9 bis. mesure : application réelle en CompactOS dans un disque virtuel --------------------------
    if (-not $SkipMeasure) {
        Say 'mesure : application de l''image en CompactOS dans un disque virtuel'
        $used = @((Get-PSDrive -PSProvider FileSystem).Name)
        $L = @('R', 'S', 'T', 'U', 'V', 'W', 'Q', 'P') | Where-Object { $used -notcontains $_ } | Select-Object -First 1
        if (-not $L) { throw 'pas de lettre libre pour le disque de mesure' }
        $vhd = Join-Path $WorkDir 'measure.vhdx'
        if (Test-Path -LiteralPath $vhd) { Remove-Item -LiteralPath $vhd -Force }
        $dp = Join-Path $WorkDir 'measure-diskpart.txt'
        @("create vdisk file=""$vhd"" maximum=65536 type=expandable", "select vdisk file=""$vhd""", 'attach vdisk',
          'create partition primary', 'format fs=ntfs quick label=RAGOMEASURE', ('assign letter={0}' -f $L)) | Set-Content -LiteralPath $dp -Encoding ASCII
        $measureDisk = $vhd
        Invoke-Native (Join-Path $env:SystemRoot 'System32\diskpart.exe') @('/s', $dp) | Out-Null
        $vol = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID = '{0}:'" -f $L)
        $emptyUsed = [double]$vol.Size - [double]$vol.FreeSpace
        Invoke-Dism @('/Apply-Image', ('/ImageFile:' + $final), '/Index:1', ('/ApplyDir:{0}:\' -f $L), '/Compact') | Out-Null
        $vol = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID = '{0}:'" -f $L)
        $after = [double]$vol.Size - [double]$vol.FreeSpace
        $q = (& (Join-Path $env:SystemRoot 'System32\compact.exe') /CompactOS:query ('/WinDir:{0}:\Windows' -f $L) 2>&1 | Out-String).Trim()
        $report.measure = [ordered]@{
            method = 'dism /Apply-Image /Compact dans un VHDX NTFS neuf (avant premier démarrage : sans pagefile, hiberfil, profil du joueur ni .NET 3.5 finalisé)'
            empty_ntfs_used_mib = Mib $emptyUsed
            applied_used_mib = Mib $after
            applied_minus_empty_mib = Mib ($after - $emptyUsed)
            compact_os_query = $q
            payload_present = (Test-Path -LiteralPath ('{0}:\Rago\bin\rago-security.ps1' -f $L))
            setupcomplete_present = (Test-Path -LiteralPath ('{0}:\Windows\Setup\Scripts\SetupComplete.cmd' -f $L))
            note = 'taille installée réelle : C:\Rago\bin\rago-report.ps1 sur la machine (RAGO-COMM\reports\m5-engine.json)'
        }
        Say ('image appliquée : {0} Mio occupés (NTFS vide : {1} Mio)' -f $report.measure.applied_used_mib, $report.measure.empty_ntfs_used_mib)
    }
    $report.result = 'ok'
} catch {
    if ($_.Exception.Message -eq 'RAGO_PLAN_ONLY_DONE') { $report.result = 'plan-only' }
    else {
        $report.result = 'erreur'
        $report.errors += $_.Exception.Message
        Write-Host ('ERREUR : ' + $_.Exception.Message) -ForegroundColor Red
    }
} finally {
    if ($hivesLoaded.Count -gt 0) { Dismount-RagoHives }
    if ($mounted -and -not $saved) {
        try { Dismount-WindowsImage -Path $Mount -Discard | Out-Null } catch { Write-Host ('!!  démontage impossible : dism /Unmount-Image /MountDir:{0} /Discard puis dism /Cleanup-Wim' -f $Mount) -ForegroundColor Red }
    }
    if ($measureDisk) {
        $dp = Join-Path $WorkDir 'measure-detach.txt'
        @("select vdisk file=""$measureDisk""", 'detach vdisk') | Set-Content -LiteralPath $dp -Encoding ASCII
        & (Join-Path $env:SystemRoot 'System32\diskpart.exe') /s $dp 2>&1 | Out-Null
        Remove-Item -LiteralPath $measureDisk -Force -ErrorAction SilentlyContinue
    }
    if ($isoMounted) { Dismount-DiskImage -ImagePath $isoMounted -ErrorAction SilentlyContinue | Out-Null }
    $report.finished_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $report.duration_minutes = [math]::Round(((Get-Date) - $t0).TotalMinutes, 1)
    $name = $(if ($PlanOnly) { 'm5-plan-report.json' } else { 'm5-build-report.json' })
    $out = Join-Path $OutputDir $name
    [System.IO.File]::WriteAllText($out, ($report | ConvertTo-Json -Depth 8) + "`n", (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ('rapport : ' + $out)
    Stop-Transcript | Out-Null
}
if ($report.result -eq 'erreur') { exit 1 }
exit 0
