# SPDX-License-Identifier: GPL-2.0
#
# Rago OS - bibliothèque partagée (module M7), côté Windows : fonctions
# communes de l'agent (C:\Rago\agent\RagoAgent.psm1).
#
# Jamais exécuté à ce jour (Windows, conteneur Linux) : validé seulement par
# lecture (windows/tests/test_agent.py).
#
#   - RAGO-COMM\library\ : contrat avec Linux (host/lib/rago_library.py) :
#       windows-state.json  écrit ici : « running » au démarrage AVANT de mettre
#                           RAGO-LIB en ligne, « off » à l'arrêt APRÈS l'avoir
#                           vidée et mise hors ligne
#       partition.json      écrit par Linux : PARTUUID de RAGO-LIB
#       requests\<id>.json  écrit par Linux : installer / lancer un jeu
#       results\<id>.json   écrit ici : où en est chaque requête
#   - RAGO-LIB : partition NTFS partagée, lettre L: (agent.json) le temps de la
#     session, hors ligne (mountvol /P) le reste du temps ; .rago\ y garde les
#     fiches des jeux (games\<clé>.json, lues par Linux) et le cache des
#     clients (cache\).
#   - script d'arrêt de la stratégie de groupe locale (SYSTEM) : met RAGO-LIB
#     hors ligne et écrit « off » à chaque arrêt ou redémarrage complet.
#
# Windows PowerShell 5.1. JSON sans BOM (Write-RagoJson de RagoComm.psm1).

Set-StrictMode -Version 2.0

$script:AgentDir = $PSScriptRoot
$script:Writer = 'rago-agent (M7)'
# Script d'arrêt : extension « Scripts » de la stratégie de groupe (MS-GPSCR).
$script:ScriptsCse = '{42B5FAAE-6536-11D2-AE5A-0000F87571E3}'
$script:ScriptsTool = '{40B6664F-4972-11D1-A7CA-0000F87571E3}'
$script:KeyRx = '^(steam|epic|riot)-[a-z0-9-]{1,80}$'
$script:ReqRx = '^(install|launch)-(steam|epic|riot)-[a-z0-9-]{1,80}$'

function Get-RagoAgentDir { return $script:AgentDir }

function Get-RagoAgentConfig {
    $cfg = Read-RagoJson (Join-Path $script:AgentDir 'agent.json')
    if ($null -eq $cfg) { throw 'agent.json absent' }
    if (-not ($cfg.lib_letter -cmatch '^[D-Z]$')) { throw ('agent.json : lettre {0} refusée (D à Z)' -f $cfg.lib_letter) }
    return $cfg
}

function Get-RagoLaunchers {
    $l = Read-RagoJson (Join-Path $script:AgentDir 'launchers.json')
    if ($null -eq $l) { throw 'launchers.json absent' }
    return $l
}

function Test-RagoProp {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Name) }
    return ($null -ne $Object.PSObject.Properties[$Name])
}

# Valeur d'un champ, ou $null s'il manque (Set-StrictMode lève une erreur sinon).
function Get-RagoPropValue {
    param($Object, [string]$Name)
    if (-not (Test-RagoProp $Object $Name)) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    return $Object.$Name
}

# --- RAGO-COMM\library ---------------------------------------------------------------------------

function Get-RagoLibraryCommDir {
    param([Parameter(Mandatory = $true)][string]$CommRoot)
    return (Join-Path $CommRoot 'library')
}

# Vide le cache d'écriture d'un volume (lettre « L » ou chemin \\?\Volume{...}\).
function Sync-RagoVolume {
    param([string]$DriveLetter, [string]$VolumePath)
    try {
        if ($DriveLetter) { Write-VolumeCache -DriveLetter $DriveLetter -ErrorAction Stop }
        elseif ($VolumePath) { Write-VolumeCache -Path $VolumePath -ErrorAction Stop }
        return $true
    } catch {
        Write-RagoLog ('vidage du cache de {0}{1} : {2}' -f $DriveLetter, $VolumePath, $_.Exception.Message) 'WARN'
        return $false
    }
}

# RAGO-COMM : lettre ou point de montage C:\Rago\comm (Get-RagoCommRoot).
function Sync-RagoComm {
    param([Parameter(Mandatory = $true)][string]$CommRoot)
    if ($CommRoot -match '^([A-Z]):\\$') { return (Sync-RagoVolume -DriveLetter $Matches[1]) }
    try {
        $v = Get-CimInstance -ClassName Win32_Volume -Filter ("Label = 'RAGO-COMM'") | Select-Object -First 1
        if ($null -ne $v) { return (Sync-RagoVolume -VolumePath ([string]$v.DeviceID)) }
    } catch { Write-RagoLog ('RAGO-COMM : ' + $_.Exception.Message) 'WARN' }
    return $false
}

function Write-RagoWindowsState {
    param(
        [Parameter(Mandatory = $true)][string]$CommRoot,
        [Parameter(Mandatory = $true)][ValidateSet('running', 'off')][string]$State,
        [Parameter(Mandatory = $true)]$Lib,
        [string]$BootId
    )
    $obj = [ordered]@{
        schema = 1
        kind = 'rago-library-windows-state'
        state = $State
        updated_at = (Get-RagoUtcNow)
        boot_id = $BootId
        writer = $script:Writer
        lib = $Lib
    }
    Write-RagoJson -Path (Join-Path (Get-RagoLibraryCommDir $CommRoot) 'windows-state.json') -InputObject $obj
    # Avant de toucher RAGO-LIB, l'état doit être sur le disque, pas dans un cache.
    [void](Sync-RagoComm -CommRoot $CommRoot)
}

function Read-RagoPartitionNote {
    param([Parameter(Mandatory = $true)][string]$CommRoot)
    $p = $null
    try { $p = Read-RagoJson (Join-Path (Get-RagoLibraryCommDir $CommRoot) 'partition.json') } catch { return $null }
    if ($null -eq $p -or -not (Test-RagoProp $p 'kind') -or $p.kind -ne 'rago-library-partition') { return $null }
    if (-not ([string]$p.partuuid -cmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')) { return $null }
    return $p
}

function Write-RagoResult {
    param(
        [Parameter(Mandatory = $true)][string]$CommRoot,
        [Parameter(Mandatory = $true)]$Request,
        [Parameter(Mandatory = $true)][ValidateSet('pending', 'waiting_user', 'running', 'done', 'failed', 'cancelled')][string]$State,
        [string]$Message = '',
        $Progress = $null,
        $Extra = $null
    )
    $obj = [ordered]@{
        schema = 1
        kind = 'rago-library-result'
        id = [string]$Request.id
        action = [string]$Request.action
        launcher = [string]$Request.launcher
        launcher_id = [string]$Request.launcher_id
        game_key = [string]$Request.game_key
        state = $State
        message = $Message
        progress = $Progress
        updated_at = (Get-RagoUtcNow)
        boot_id = (Get-RagoBootId)
        writer = $script:Writer
    }
    if ($null -ne $Extra) { foreach ($k in $Extra.Keys) { $obj[$k] = $Extra[$k] } }
    Write-RagoJson -Path (Join-Path (Get-RagoLibraryCommDir $CommRoot) ('results\{0}.json' -f $Request.id)) -InputObject $obj
}

# Requêtes de Linux, validées (mêmes règles que rago_library.py).
function Get-RagoRequests {
    param([Parameter(Mandatory = $true)][string]$CommRoot)
    $dir = Join-Path (Get-RagoLibraryCommDir $CommRoot) 'requests'
    $out = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $r = $null
        try { $r = Read-RagoJson $f.FullName } catch { Write-RagoLog ('requête illisible {0} : {1}' -f $f.Name, $_.Exception.Message) 'WARN'; continue }
        $ok = (Test-RagoProp $r 'kind') -and $r.kind -eq 'rago-library-request' -and (Test-RagoProp $r 'id') -and
            ([string]$r.id -cmatch $script:ReqRx) -and ($f.Name -ceq ([string]$r.id + '.json')) -and
            (Test-RagoProp $r 'game_key') -and ([string]$r.game_key -cmatch $script:KeyRx) -and
            (Test-RagoProp $r 'launcher_id') -and (Test-RagoProp $r 'action')
        if (-not $ok) { Write-RagoLog ('requête refusée : {0}' -f $f.Name) 'WARN'; continue }
        $out += $r
    }
    return $out
}

# Résultats pas finis d'une session précédente (à reprendre).
function Get-RagoOpenResults {
    param([Parameter(Mandatory = $true)][string]$CommRoot)
    $dir = Join-Path (Get-RagoLibraryCommDir $CommRoot) 'results'
    $out = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $r = $null
        try { $r = Read-RagoJson $f.FullName } catch { continue }
        if ((Test-RagoProp $r 'state') -and @('pending', 'waiting_user', 'running') -contains [string]$r.state -and
            (Test-RagoProp $r 'id') -and ([string]$r.id -cmatch $script:ReqRx)) { $out += $r }
    }
    return $out
}

# --- RAGO-LIB : partition, en ligne / hors ligne --------------------------------------------------

function Find-RagoLibPartition {
    param($Note)
    if ($null -ne $Note) {
        $guid = '{' + ([string]$Note.partuuid).ToLowerInvariant() + '}'
        $p = @(Get-Partition -ErrorAction SilentlyContinue | Where-Object { $_.Guid -and ([string]$_.Guid).ToLowerInvariant() -eq $guid })
        if ($p.Count -eq 1) { return $p[0] }
        if ($p.Count -gt 1) { throw ('{0} partitions avec le PARTUUID {1}' -f $p.Count, $guid) }
        Write-RagoLog ('partition {0} (partition.json) introuvable' -f $guid) 'WARN'
    }
    # Repli : par étiquette, seulement si le volume est en ligne (hors ligne, l'étiquette est illisible).
    $v = @(Get-Volume -FileSystemLabel 'RAGO-LIB' -ErrorAction SilentlyContinue)
    if ($v.Count -eq 1) { return (Get-Partition -Volume $v[0]) }
    if ($v.Count -gt 1) { throw ('{0} volumes nommés RAGO-LIB' -f $v.Count) }
    return $null
}

function Get-RagoVolumeGuidPath {
    param([Parameter(Mandatory = $true)]$Partition)
    foreach ($a in @($Partition.AccessPaths)) {
        if ([string]$a -match '^\\\\\?\\Volume\{[0-9a-fA-F-]{36}\}\\$') { return [string]$a }
    }
    return $null
}

# Volume hors ligne ? Demandé à Windows (IOCTL_VOLUME_IS_OFFLINE, winioctl.h :
# CTL_CODE(IOCTL_VOLUME_BASE 'V', 4, METHOD_BUFFERED, FILE_ANY_ACCESS) = 0x00560010)
# sur le périphérique \\.\Volume{GUID}, ouvert sans accès aux données (pas de
# remontage). $true SEULEMENT si Windows le confirme ; $false au moindre doute
# (Linux restera alors en lecture seule). Pas de test de lecture du chemin
# \\?\Volume{...}\ : les méthodes .NET de Windows PowerShell 5.1 peuvent refuser
# ce chemin, ce qui ferait croire à tort le volume hors ligne.
$script:VolumeNativeCs = @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class RagoVolumeNative {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(SafeFileHandle h, uint code, IntPtr inBuf, uint inSize, IntPtr outBuf, uint outSize, out uint returned, IntPtr overlapped);
    const uint IOCTL_VOLUME_IS_OFFLINE = 0x00560010;
    // FSCTL_IS_VOLUME_DIRTY = CTL_CODE(FILE_DEVICE_FILE_SYSTEM 9, 30, METHOD_BUFFERED, FILE_ANY_ACCESS)
    const uint FSCTL_IS_VOLUME_DIRTY = 0x00090078;
    public static bool IsOffline(string device) {
        using (SafeFileHandle h = CreateFileW(device, 0, 3, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
            if (h.IsInvalid) { return false; }
            uint n;
            return DeviceIoControl(h, IOCTL_VOLUME_IS_OFFLINE, IntPtr.Zero, 0, IntPtr.Zero, 0, out n, IntPtr.Zero);
        }
    }
    // 1 : volume marqué « sale » (VOLUME_IS_DIRTY) ; 0 : propre ; -1 : illisible.
    public static int IsDirty(string device) {
        using (SafeFileHandle h = CreateFileW(device, 0x80000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
            if (h.IsInvalid) { return -1; }
            IntPtr buf = Marshal.AllocHGlobal(4);
            try {
                Marshal.WriteInt32(buf, 0);
                uint n;
                if (!DeviceIoControl(h, FSCTL_IS_VOLUME_DIRTY, IntPtr.Zero, 0, buf, 4, out n, IntPtr.Zero) || n < 4) { return -1; }
                return (Marshal.ReadInt32(buf) & 1) != 0 ? 1 : 0;
            } finally { Marshal.FreeHGlobal(buf); }
        }
    }
}
'@

function Test-RagoVolumeOffline {
    param([string]$VolumePath)
    # Même motif que Get-RagoVolumeGuidPath : deux barres obliques inverses au début.
    if (-not ($VolumePath -cmatch '^\\\\\?\\(Volume\{[0-9a-fA-F-]{36}\})\\$')) { return $false }
    $dev = '\\.\' + $Matches[1]
    try {
        if ($null -eq ('RagoVolumeNative' -as [type])) { Add-Type -TypeDefinition $script:VolumeNativeCs }
        return [bool][RagoVolumeNative]::IsOffline($dev)
    } catch {
        Write-RagoLog ('état hors ligne de {0} illisible : {1}' -f $dev, $_.Exception.Message) 'WARN'
        return $false
    }
}

# Volume marqué « sale » ? $true / $false, ou $null si Windows ne répond pas (doute).
function Test-RagoVolumeDirty {
    param([Parameter(Mandatory = $true)][string]$Letter)
    if (-not ($Letter -cmatch '^[D-Z]$')) { return $null }
    try {
        if ($null -eq ('RagoVolumeNative' -as [type])) { Add-Type -TypeDefinition $script:VolumeNativeCs }
        $d = [RagoVolumeNative]::IsDirty('\\.\' + $Letter + ':')
    } catch {
        Write-RagoLog ('état « sale » de {0}: illisible : {1}' -f $Letter, $_.Exception.Message) 'WARN'
        return $null
    }
    if ($d -eq 1) { return $true }
    if ($d -eq 0) { return $false }
    return $null
}

# RAGO-LIB est hors ligne au démarrage : autochk ne la vérifie donc jamais.
# Si elle est marquée « sale » (Linux coupé pendant un montage en écriture,
# ou Windows a demandé une vérification), on la répare AVANT que quiconque y
# écrive (rien n'utilise encore la lettre). Réparation hors ligne de Windows
# (Repair-Volume -OfflineScanAndFix, l'équivalent de chkdsk /f). Réussie
# seulement si le volume n'est plus marqué « sale » ensuite.
function Repair-RagoLibIfDirty {
    param([Parameter(Mandatory = $true)][string]$Letter)
    $res = [ordered]@{ dirty = (Test-RagoVolumeDirty -Letter $Letter); repair = $null; ok = $false }
    if ($res.dirty -eq $false) { $res.ok = $true; return $res }
    Write-RagoLog ('RAGO-LIB ({0}:) sale ou état illisible : réparation hors ligne' -f $Letter) 'WARN'
    try {
        $r = Repair-Volume -DriveLetter $Letter -OfflineScanAndFix -ErrorAction Stop
        $res.repair = [string]$r
    } catch {
        $res.repair = ('échec : ' + $_.Exception.Message)
        return $res
    }
    $after = Test-RagoVolumeDirty -Letter $Letter
    $res.ok = ($after -eq $false)
    if (-not $res.ok) { $res.repair += ' ; toujours marquée sale (ou état illisible) après la réparation' }
    return $res
}

function Get-RagoLetters {
    param([Parameter(Mandatory = $true)]$Partition)
    $l = @()
    foreach ($a in @($Partition.AccessPaths)) { if ([string]$a -match '^([A-Z]):\\$') { $l += $Matches[1] } }
    return $l
}

# Programme natif : sa sortie d'erreur ne doit pas devenir une exception
# (Windows PowerShell 5.1 + 2>&1 + « Stop ») ; seul le code de sortie compte.
function Invoke-RagoNative {
    param([Parameter(Mandatory = $true)][string]$FilePath, [string[]]$Arguments = @())
    $ErrorActionPreference = 'Continue'
    $out = & $FilePath @Arguments 2>&1
    $code = $LASTEXITCODE
    $text = (@($out | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
    return [pscustomobject]@{ code = $code; output = $text }
}

function Invoke-RagoMountvol {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    return (Invoke-RagoNative -FilePath (Join-Path $env:SystemRoot 'System32\mountvol.exe') -Arguments $Arguments)
}

# Met RAGO-LIB en ligne sur sa lettre. Renvoie l'état pour windows-state.json.
function Mount-RagoLib {
    param([Parameter(Mandatory = $true)]$Partition, [Parameter(Mandatory = $true)][string]$Letter)
    $lib = [ordered]@{ found = $true; partuuid = ([string]$Partition.Guid).Trim('{}').ToLowerInvariant(); letter = $null; online = $false; offline = $false; error = $null }
    $vol = Get-RagoVolumeGuidPath $Partition
    if ($null -eq $vol) { $lib.error = 'chemin \\?\Volume{...} introuvable'; return $lib }
    $have = @(Get-RagoLetters $Partition)
    if ($have -notcontains $Letter) {
        $taken = Get-Volume -DriveLetter $Letter -ErrorAction SilentlyContinue
        if ($null -ne $taken -or (Test-Path -LiteralPath ($Letter + ':\'))) {
            $lib.error = ('lettre {0}: prise par un autre volume : RAGO-LIB pas mise sur {0}: ni utilisée (retirer ce volume, puis redémarrer)' -f $Letter)
            # Hors ligne seulement si Windows ne l'a pas montée d'office sur une autre lettre.
            $lib.offline = ($have.Count -eq 0 -and (Test-RagoVolumeOffline $vol))
            return $lib
        }
        # Un point de montage remet en ligne un volume sorti par mountvol /P (doc Microsoft de mountvol).
        $r = Invoke-RagoMountvol @(($Letter + ':\'), $vol)
        if ($r.code -ne 0) { $lib.error = ('mountvol {0}:\ : code {1} {2}' -f $Letter, $r.code, $r.output); return $lib }
    }
    $root = $Letter + ':\'
    for ($i = 0; $i -lt 20 -and -not (Test-Path -LiteralPath $root); $i++) { Start-Sleep -Milliseconds 500 }
    if (-not (Test-Path -LiteralPath $root)) { $lib.error = ('{0} illisible après la mise en ligne' -f $root); return $lib }
    # Une seule lettre : un client qui retiendrait une autre lettre (montage
    # automatique de Windows) perdrait son chemin à l'arrêt.
    foreach ($x in $have) {
        if ($x -eq $Letter) { continue }
        $r = Invoke-RagoMountvol @(($x + ':\'), '/D')
        if ($r.code -ne 0) { Write-RagoLog ('RAGO-LIB : lettre {0}: pas retirée : {1}' -f $x, $r.output) 'WARN' }
        else { Write-RagoLog ('RAGO-LIB : lettre {0}: retirée (seule {1}: reste)' -f $x, $Letter) }
    }
    $v = Get-Volume -DriveLetter $Letter -ErrorAction SilentlyContinue
    if ($null -ne $v -and [string]$v.FileSystem -ne 'NTFS') { $lib.error = ('{0} est en {1}, NTFS attendu' -f $root, $v.FileSystem) }
    $lib.letter = $Letter
    $lib.online = $true
    return $lib
}

# Vide puis met RAGO-LIB hors ligne (mountvol <lettre> /P : démonte et rend le
# volume inutilisable jusqu'au prochain point de montage). Vérifie ensuite auprès
# de Windows que le volume est hors ligne (Test-RagoVolumeOffline).
function Dismount-RagoLib {
    param([Parameter(Mandatory = $true)]$Partition)
    $lib = [ordered]@{ found = $true; partuuid = ([string]$Partition.Guid).Trim('{}').ToLowerInvariant(); letter = $null; online = $false; offline = $false; flushed = $false; error = $null }
    $vol = Get-RagoVolumeGuidPath $Partition
    $letters = @(Get-RagoLetters $Partition)
    if ($letters.Count -eq 0) {
        if ($null -eq $vol) { $lib.error = 'ni lettre ni chemin de volume'; return $lib }
        # Pas de lettre : déjà hors ligne (arrêt précédent) ou jamais mise en ligne ce démarrage.
        $lib.offline = Test-RagoVolumeOffline $vol
        if (-not $lib.offline) {
            # En ligne sans lettre (inattendu) : Win32_Volume.Dismount(Force, Permanent),
            # « démonté, sans montage automatique, hors ligne » (doc Microsoft).
            $lib.flushed = Sync-RagoVolume -VolumePath $vol
            try {
                $wv = Get-CimInstance -ClassName Win32_Volume -Filter ("DeviceID = '{0}'" -f $vol.Replace('\', '\\'))
                $r = Invoke-CimMethod -InputObject $wv -MethodName Dismount -Arguments @{ Force = $true; Permanent = $true }
                if ($r.ReturnValue -ne 0) { $lib.error = ('Win32_Volume.Dismount : code {0}' -f $r.ReturnValue) }
            } catch { $lib.error = ('Win32_Volume.Dismount : ' + $_.Exception.Message) }
            $lib.offline = Test-RagoVolumeOffline $vol
            if (-not $lib.offline -and -not $lib.error) { $lib.error = 'RAGO-LIB pas hors ligne après Dismount' }
        }
        return $lib
    }
    $lib.flushed = Sync-RagoVolume -DriveLetter $letters[-1]
    for ($i = 0; $i -lt $letters.Count - 1; $i++) {
        $r = Invoke-RagoMountvol @(($letters[$i] + ':\'), '/D')
        if ($r.code -ne 0) { Write-RagoLog ('mountvol {0}: /D : {1}' -f $letters[$i], $r.output) 'WARN' }
    }
    $r = Invoke-RagoMountvol @(($letters[-1] + ':\'), '/P')
    if ($r.code -ne 0) { $lib.error = ('mountvol {0}:\ /P : code {1} {2}' -f $letters[-1], $r.code, $r.output); return $lib }
    # Sans chemin \\?\Volume{...} rien ne prouve la mise hors ligne : « offline » reste faux
    # (Linux restera en lecture seule, côté prudent).
    if ($null -ne $vol) { $lib.offline = Test-RagoVolumeOffline $vol }
    if (-not $lib.offline -and -not $lib.error) {
        if ($null -eq $vol) { $lib.error = 'mise hors ligne non vérifiable (pas de chemin \\?\Volume{...})' }
        else { $lib.error = 'Windows ne confirme pas RAGO-LIB hors ligne après mountvol /P' }
    }
    return $lib
}

# Les clients (compte du joueur) doivent pouvoir écrire dans RAGO-LIB.
function Grant-RagoLibUsers {
    param([Parameter(Mandatory = $true)][string]$Root)
    $acl = Get-Acl -LiteralPath $Root
    $want = @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545')
    foreach ($ace in $acl.Access) {
        $sid = $null
        try { $sid = $ace.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { continue }
        $rights = [int]$ace.FileSystemRights
        $modify = [int][System.Security.AccessControl.FileSystemRights]::Modify
        if ($want -contains $sid -and $ace.AccessControlType -eq 'Allow' -and (($rights -band $modify) -eq $modify)) { return 'déjà' }
    }
    $r = Invoke-RagoNative -FilePath (Join-Path $env:SystemRoot 'System32\icacls.exe') -Arguments @($Root, '/grant', '*S-1-5-32-545:(OI)(CI)M', '/C', '/Q')
    if ($r.code -ne 0) { throw ('icacls {0} : {1}' -f $Root, $r.output) }
    return 'Utilisateurs : modification'
}

# Même arborescence que « rago_library.py init » (Linux).
function Initialize-RagoLibTree {
    param([Parameter(Mandatory = $true)][string]$Root)
    foreach ($d in @('.rago', '.rago\games', '.rago\cache', 'Games', 'Games\Steam', 'Games\Epic', 'Games\Riot')) {
        $p = Join-Path $Root $d
        if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    }
    $lj = Join-Path $Root '.rago\library.json'
    if (-not (Test-Path -LiteralPath $lj)) {
        Write-RagoJson -Path $lj -InputObject ([ordered]@{
                schema = 1; kind = 'rago-library'; layout = 1; label = 'RAGO-LIB'; created_at = (Get-RagoUtcNow); writer = $script:Writer
                doc = 'Bibliotheque de jeux Windows de Rago OS (M7). Jeux installes par les clients officiels dans le micro-Windows. Jamais ouverte par Linux et Windows en meme temps.'
            })
    }
}

# --- fiches des jeux (RAGO-LIB\.rago\games) ------------------------------------------------------

function Read-RagoGameRecord {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Key)
    if (-not ($Key -cmatch $script:KeyRx)) { throw ('clé de jeu {0} refusée' -f $Key) }
    try { return (Read-RagoJson (Join-Path $Root ('.rago\games\{0}.json' -f $Key))) } catch { return $null }
}

function Write-RagoGameRecord {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)]$Record)
    if (-not ([string]$Record.key -cmatch $script:KeyRx)) { throw ('clé de jeu {0} refusée' -f $Record.key) }
    $Record.schema = 1
    $Record.kind = 'rago-library-game'
    $Record.updated_at = (Get-RagoUtcNow)
    $Record.writer = $script:Writer
    Write-RagoJson -Path (Join-Path $Root ('.rago\games\{0}.json' -f $Record.key)) -InputObject $Record
}

# Chemin Windows sous RAGO-LIB -> chemin relatif « / » pour Linux (ou $null hors de RAGO-LIB).
function ConvertTo-RagoLibRelative {
    param([Parameter(Mandatory = $true)][string]$Root, [string]$Path)
    if (-not $Path) { return $null }
    $full = [System.IO.Path]::GetFullPath($Path.Replace('/', '\'))
    $r = [System.IO.Path]::GetFullPath($Root)
    if (-not $full.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
    return $full.Substring($r.Length).TrimStart('\').Replace('\', '/')
}

# Identité de CETTE installation de Windows (change à chaque reconstruction de l'image).
function Get-RagoWindowsInstallId {
    $g = $null
    try { $g = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid } catch { $g = $null }
    if ($g) { return [string]$g }
    return 'inconnue'
}

# --- script d'arrêt (stratégie de groupe locale) ----------------------------------------------------

# Pose le script d'arrêt « rago-agent.ps1 -Shutdown » (SYSTEM, à chaque arrêt
# ou redémarrage complet ; jamais en veille prolongée, coupée par M5).
# Fichiers de MS-GPSCR : scripts.ini en UTF-16LE avec BOM, gpt.ini avec
# l'extension Scripts dans gPCMachineExtensionNames et Version + 1 (partie
# ordinateur). Windows les prend en compte au démarrage suivant.
function Set-RagoShutdownScript {
    $gp = Join-Path $env:SystemRoot 'System32\GroupPolicy'
    $dir = Join-Path $gp 'Machine\Scripts'
    $ini = Join-Path $dir 'scripts.ini'
    $cmd = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $prm = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Shutdown' -f (Join-Path $script:AgentDir 'rago-agent.ps1')
    $want = "[Shutdown]`r`n0CmdLine=$cmd`r`n0Parameters=$prm`r`n"
    $changed = $false
    $cur = $null
    if (Test-Path -LiteralPath $ini) { $cur = [System.IO.File]::ReadAllText($ini) }
    if ($cur -ne $want) {
        if ($null -ne $cur -and $cur.Trim().Length -gt 0) {
            Copy-Item -LiteralPath $ini -Destination ($ini + '.rago-avant') -Force
            Write-RagoLog ('scripts.ini remplacé (ancien gardé : {0}.rago-avant)' -f $ini) 'WARN'
        }
        New-Item -ItemType Directory -Path (Join-Path $dir 'Shutdown') -Force | Out-Null
        # -Encoding Unicode de Windows PowerShell 5.1 : UTF-16LE avec BOM (exigé par MS-GPSCR).
        Set-Content -LiteralPath $ini -Value $want -Encoding Unicode -NoNewline
        $changed = $true
    }
    $gptIni = Join-Path $gp 'gpt.ini'
    $lines = @()
    if (Test-Path -LiteralPath $gptIni) { $lines = @([System.IO.File]::ReadAllLines($gptIni)) }
    $names = ''; $version = 0; $other = @()
    foreach ($l in $lines) {
        if ($l -match '^\s*gPCMachineExtensionNames\s*=\s*(.*)$') { $names = $Matches[1].Trim() }
        elseif ($l -match '^\s*Version\s*=\s*(\d+)\s*$') { $version = [int64]$Matches[1] }
        elseif ($l -match '^\s*\[General\]\s*$' -or $l.Trim() -eq '' -or $l -match '^\s*gPCFunctionalityVersion\s*=') { }
        else { $other += $l }
    }
    $pairs = @([regex]::Matches($names, '\[(\{[0-9A-Fa-f-]{36}\})(\{[0-9A-Fa-f-]{36}\})*\]') | ForEach-Object { $_.Value })
    $has = $false
    foreach ($p in $pairs) { if ($p.ToUpperInvariant().StartsWith('[' + $script:ScriptsCse)) { $has = $true } }
    if (-not $has) {
        $pairs += ('[{0}{1}]' -f $script:ScriptsCse, $script:ScriptsTool)
        $changed = $true
    }
    if ($changed) {
        # Tri par GUID d'extension (MS-GPOL : le traitement s'arrête au premier désordre).
        $pairs = @($pairs | Sort-Object { $_.Substring(1, 38).ToUpperInvariant() })
        # Version : 16 bits du haut = utilisateur, 16 bits du bas = ordinateur (MS-GPOL).
        $userPart = [math]::Floor($version / 65536)
        $machine = (($version % 65536) + 1) % 65536
        $version = [int64]($userPart * 65536 + $machine)
        $out = @('[General]', 'gPCFunctionalityVersion=2', ('gPCMachineExtensionNames=' + ($pairs -join '')), ('Version={0}' -f $version)) + $other
        Set-Content -LiteralPath $gptIni -Value (($out -join "`r`n") + "`r`n") -Encoding Ascii -NoNewline
        Write-RagoLog ('script d''arrêt de RAGO-LIB posé (stratégie locale, version {0}) : actif au démarrage suivant' -f $version)
    }
    $state = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\Machine\Scripts\Shutdown'
    $registered = $false
    foreach ($k in @(Get-ChildItem -LiteralPath $state -Recurse -ErrorAction SilentlyContinue)) {
        $s = Get-ItemProperty -LiteralPath $k.PSPath -Name Script -ErrorAction SilentlyContinue
        if ($null -ne $s -and [string]$s.Script -like '*powershell.exe') {
            $pp = Get-ItemProperty -LiteralPath $k.PSPath -Name Parameters -ErrorAction SilentlyContinue
            if ($null -ne $pp -and [string]$pp.Parameters -like '*rago-agent.ps1*-Shutdown*') { $registered = $true }
        }
    }
    return [ordered]@{ files_changed = $changed; registered = $registered }
}

Export-ModuleMember -Function Get-RagoAgentDir, Get-RagoAgentConfig, Get-RagoLaunchers, Test-RagoProp, Get-RagoPropValue, Get-RagoLibraryCommDir,
    Sync-RagoVolume, Sync-RagoComm, Write-RagoWindowsState, Read-RagoPartitionNote, Write-RagoResult, Get-RagoRequests,
    Get-RagoOpenResults, Find-RagoLibPartition, Get-RagoVolumeGuidPath, Test-RagoVolumeOffline, Test-RagoVolumeDirty, Repair-RagoLibIfDirty, Get-RagoLetters, Invoke-RagoNative, Invoke-RagoMountvol, Mount-RagoLib,
    Dismount-RagoLib, Grant-RagoLibUsers, Initialize-RagoLibTree, Read-RagoGameRecord, Write-RagoGameRecord,
    ConvertTo-RagoLibRelative, Get-RagoWindowsInstallId, Set-RagoShutdownScript
