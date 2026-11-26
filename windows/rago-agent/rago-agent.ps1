# SPDX-License-Identifier: GPL-2.0
<#
.SYNOPSIS
    Agent de la bibliothèque partagée du micro-Windows Rago (module M7).

.DESCRIPTION
    Installé dans C:\Rago\agent\ (copié par compile_micro_engine.ps1).
    Jamais exécuté à ce jour (Windows, conteneur Linux).

    -Boot      (compte SYSTEM, appelé par rago-boot.ps1 à chaque démarrage)
               1. écrit « running » dans RAGO-COMM\library\windows-state.json
                  AVANT de toucher RAGO-LIB (Linux restera en lecture seule
                  si Windows ne s'arrête pas proprement) ;
               2. met RAGO-LIB en ligne sur sa lettre (agent.json, L:), trouvée
                  par son PARTUUID (RAGO-COMM\library\partition.json, écrit par
                  Linux) ; sans RAGO-COMM, l'agent ne la met pas en ligne (et la
                  remet hors ligne si Windows l'a montée d'office, étape 4) ;
                  Volume marqué « sale » (Linux coupé pendant une écriture, ou
                  vérification demandée) : réparé hors ligne (Repair-Volume)
                  AVANT toute écriture, sinon laissé hors ligne ;
               3. droits d'écriture des clients sur la racine de RAGO-LIB (SYSTEM
                  ne lit ni n'écrit rien d'autre dans RAGO-LIB, modifiable par
                  les Utilisateurs) ;
               4. RAGO-LIB pas utilisée (pas de RAGO-COMM, lettre prise, volume
                  sale...) mais montée d'office par Windows : remise hors ligne ;
               5. runtime VC++ installé depuis C:\Rago\redist s'il manque ;
               6. note la session dans C:\ProgramData\Rago\library-boot.json.
    -Shutdown  (compte SYSTEM, script d'arrêt de la stratégie locale) : marque
               l'arrêt (une mise en ligne pas commencée n'aura pas lieu), attend
               la fin d'une mise en ligne en cours (verrou partagé avec -Boot),
               vide le cache de RAGO-LIB, la met hors ligne (mountvol /P), puis
               écrit « off » (avec lib.offline) dans RAGO-COMM.
    -Session   (compte du joueur, lancé par rago-shell.ps1) : arborescence
               .rago\ et finalisation des jeux sur CETTE installation de Windows
               (métadonnées des clients remises depuis RAGO-LIB\.rago\cache) ;
               prend les requêtes de Linux (RAGO-COMM\library\requests), ouvre le client
               officiel au bon endroit, suit l'installation, écrit les
               résultats (RAGO-COMM\library\results) et les fiches des jeux
               (RAGO-LIB\.rago\games).
    -Status    affiche l'état.
    -Abandon   ID : passe une requête en « cancelled » (menu du shell).
    -RegisterShutdown : pose seulement le script d'arrêt (rago-boot.ps1).
#>
[CmdletBinding()]
param(
    [switch]$Boot,
    [switch]$Shutdown,
    [switch]$Session,
    [switch]$Status,
    [switch]$RegisterShutdown,
    [string]$Abandon,
    # -Session : attente de library-boot.json de CE démarrage (tâche \Rago\Boot).
    [ValidateRange(0, 3600)][int]$WaitSeconds = 0
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'bin\RagoComm.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'RagoAgent.psm1') -Force
$bootInfoPath = Join-Path (Get-RagoDataDir) 'library-boot.json'
$shutdownMarkPath = Join-Path (Get-RagoDataDir) 'library-shutdown.json'
$localNotePath = Join-Path (Get-RagoDataDir) 'library-partition.json'

# --- verrou entre -Boot et -Shutdown (tous deux en SYSTEM) ------------------------------------------
# L'arrêt ne doit pas croiser une mise en ligne en cours (le joueur peut
# éteindre pendant que la tâche \Rago\Boot tourne encore) : -Shutdown écrit
# d'abord sa marque (library-shutdown.json, pour CE démarrage), puis attend
# le verrou ; -Boot prend le verrou et renonce s'il voit la marque.
function Enter-RagoLibraryLock {
    param([int]$Seconds)
    $m = New-Object System.Threading.Mutex($false, 'Global\RagoLibraryVolume')
    $got = $false
    try { $got = $m.WaitOne([TimeSpan]::FromSeconds($Seconds)) }
    catch {
        $ex = $_.Exception
        # Verrou abandonné (processus tué) : il nous revient.
        if ($ex -is [System.Threading.AbandonedMutexException] -or $ex.InnerException -is [System.Threading.AbandonedMutexException]) { $got = $true }
        else { $m.Dispose(); throw }
    }
    if (-not $got) { $m.Dispose(); return $null }
    return $m
}

function Exit-RagoLibraryLock {
    param($Mutex)
    if ($null -eq $Mutex) { return }
    try { $Mutex.ReleaseMutex() } finally { $Mutex.Dispose() }
}

function Test-RagoShutdownStarted {
    $m = $null
    try { $m = Read-RagoJson $shutdownMarkPath } catch { return $false }
    return ($null -ne $m -and (Test-RagoProp $m 'boot_id') -and [string]$m.boot_id -eq (Get-RagoBootId))
}

# PARTUUID de RAGO-LIB gardé par Windows quand il l'a trouvée par son étiquette
# (partition.json de Linux absent) : hors ligne, l'étiquette est illisible.
function Read-RagoLocalPartitionNote {
    $p = $null
    try { $p = Read-RagoJson $localNotePath } catch { return $null }
    if ($null -eq $p -or -not (Test-RagoProp $p 'kind') -or $p.kind -ne 'rago-library-partition') { return $null }
    if (-not ([string]$p.partuuid -cmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')) { return $null }
    return $p
}

function Get-RagoPartitionNoteAny {
    param($Comm)
    $n = $null
    if ($Comm) { $n = Read-RagoPartitionNote $Comm }
    if ($null -eq $n) { $n = Read-RagoLocalPartitionNote }
    return $n
}

# --- démarrage (SYSTEM) -----------------------------------------------------------------------------

function Test-RagoVcRuntime {
    $ok = $true
    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x86')) {
        $v = Get-ItemProperty -LiteralPath $k -Name Installed -ErrorAction SilentlyContinue
        if ($null -eq $v -or [int]$v.Installed -ne 1) { $ok = $false }
    }
    return $ok
}

function Install-RagoVcFromRedist {
    $dir = Join-Path (Get-RagoRootDir) 'redist'
    $done = @()
    foreach ($vc in @(Get-ChildItem -LiteralPath $dir -Filter 'VC_redist.*.exe' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $p = Start-Process -FilePath $vc.FullName -ArgumentList @('/install', '/quiet', '/norestart') -PassThru -Wait -WindowStyle Hidden
        $done += ('{0} : code {1}' -f $vc.Name, $p.ExitCode)
    }
    return $done
}

# Remet un fichier de métadonnées d'un client depuis RAGO-LIB\.rago\cache s'il manque.
function Restore-RagoClientFile {
    param([string]$From, [string]$To)
    if (-not $From -or -not (Test-Path -LiteralPath $From)) { return 'pas de copie dans .rago\cache' }
    if (Test-Path -LiteralPath $To) { return 'déjà là' }
    New-Item -ItemType Directory -Path (Split-Path -Parent $To) -Force | Out-Null
    Copy-Item -LiteralPath $From -Destination $To -Force
    return ('remis (méthode non officielle, à vérifier) : ' + $To)
}

# Lancé dans la SESSION du joueur (pas en SYSTEM) : les fiches et le cache de
# RAGO-LIB sont modifiables par les Utilisateurs ; les métadonnées des clients
# sont remises avec les droits des clients eux-mêmes.
function Invoke-RagoFinalize {
    param([Parameter(Mandatory = $true)][string]$Root)
    $wid = Get-RagoWindowsInstallId
    $L = Get-RagoLaunchers
    # Installé au démarrage (SYSTEM) depuis C:\Rago\redist s'il manquait ; ici, seulement lu.
    $vcOk = Test-RagoVcRuntime
    $vcChecked = 'présent'
    if (-not $vcOk) { $vcChecked = 'absent : à installer (VC_redist dans C:\Rago\redist à la construction ; le client le fera peut-être)' }
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $Root '.rago\games') -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $g = $null
        try { $g = Read-RagoJson $f.FullName } catch { Write-RagoLog ('fiche illisible {0}' -f $f.Name) 'WARN'; continue }
        if ($null -eq $g -or -not (Test-RagoProp $g 'key') -or ($f.Name -ne ([string]$g.key + '.json'))) { continue }
        if (-not (Test-RagoProp $g 'installed') -or -not $g.installed) { continue }
        if ((Test-RagoProp $g 'finalized') -and $null -ne $g.finalized -and (Test-RagoProp $g.finalized 'windows_install_id') -and
            [string]$g.finalized.windows_install_id -eq $wid) { continue }
        $steps = [ordered]@{}
        $steps.vc_runtime = $vcChecked
        $cache = Join-Path $Root '.rago\cache'
        switch ([string]$g.launcher) {
            'steam' { $steps.client = 'Steam refait lui-même la préparation du jeu (scripts d''installation) au premier lancement' }
            'epic' {
                $app = Get-RagoEpicAppNameLocal ([string]$g.launcher_id)
                $guid = [string](Get-RagoPropValue (Get-RagoPropValue $g 'client_ids') 'installation_guid')
                if (-not ($app -cmatch '^[A-Za-z0-9._-]{1,64}$') -or $app -match '^\.+$') { $steps.client = ('AppName Epic {0} refusé' -f $app) }
                elseif ($guid -match '^[0-9A-Fa-f]{32}$') {
                    $steps.client = Restore-RagoClientFile -From (Join-Path $cache ('epic\{0}.item' -f $app)) -To (Join-Path ([Environment]::ExpandEnvironmentVariables($L.epic.manifests_dir)) ($guid + '.item'))
                } else { $steps.client = 'pas d''identifiant d''installation Epic : réinstaller ou « Vérifier » dans le lanceur' }
            }
            'riot' {
                $p = [string]$g.launcher_id
                if ($p -cmatch '^[a-z][a-z0-9_]{0,31}$') {
                    $steps.client = Restore-RagoClientFile -From (Join-Path $cache ('riot\{0}.live.product_settings.yaml' -f $p)) -To (Join-Path ([Environment]::ExpandEnvironmentVariables($L.riot.metadata_dir)) ('{0}.live\{0}.live.product_settings.yaml' -f $p))
                }
            }
        }
        if (-not $vcOk) {
            # Pas « finalisé » tant que le runtime manque : réessayé à la session suivante.
            Write-RagoLog ('jeu {0} : runtime VC++ absent, finalisation pas notée ({1})' -f $g.key, (($steps.Values | ForEach-Object { [string]$_ }) -join ' ; ')) 'WARN'
            continue
        }
        $rec = [ordered]@{}
        foreach ($pp in $g.PSObject.Properties) { $rec[$pp.Name] = $pp.Value }
        $rec.finalized = [ordered]@{ windows_install_id = $wid; at = (Get-RagoUtcNow); steps = $steps }
        Write-RagoGameRecord -Root $Root -Record $rec
        Write-RagoLog ('jeu {0} finalisé pour cette installation de Windows' -f $g.key)
    }
}

function Get-RagoEpicAppNameLocal {
    param([string]$Id)
    $parts = $Id.Split(':')
    return $parts[$parts.Count - 1]
}

# VC++ 2015-2022 : vérifié à chaque démarrage, installé depuis C:\Rago\redist
# (fourni par le joueur à la construction, dossier des administrateurs) s'il manque.
# Ne lit rien dans RAGO-LIB.
function Update-RagoVcRuntime {
    if (Test-RagoVcRuntime) { return 'présent' }
    $r = @(Install-RagoVcFromRedist)
    if ($r.Count -eq 0) { return 'absent (ni dans Windows ni dans C:\Rago\redist)' }
    if (Test-RagoVcRuntime) { return ('installé depuis C:\Rago\redist : ' + ($r -join ' ; ')) }
    return ('toujours absent après ' + ($r -join ' ; '))
}

# RAGO-LIB pas utilisée pendant cette session (pas de RAGO-COMM, lettre prise,
# volume sale...) : si Windows l'a montée d'office (premier démarrage, ou
# mise hors ligne pas gardée), on la remet hors ligne. Seulement avec le verrou.
function Close-RagoLibIfOnline {
    param($Comm)
    $part = Find-RagoLibPartition (Get-RagoPartitionNoteAny $Comm)
    if ($null -eq $part) { return $null }
    return (Dismount-RagoLib -Partition $part)
}

function Invoke-RagoAgentBoot {
    Set-RagoLogName 'agent'
    $bootId = Get-RagoBootId
    $info = [ordered]@{ schema = 1; kind = 'rago-library-boot'; boot_id = $bootId; written_at = (Get-RagoUtcNow); comm_root = $null; lib_root = $null; lib = $null; lib_closed = $null; vc_runtime = $null; shutdown_script = $null; errors = @() }
    try { $info.shutdown_script = Set-RagoShutdownScript } catch { $info.errors += ('script d''arrêt : ' + $_.Exception.Message) }
    $lock = $null
    $comm = $null
    try {
        $lock = Enter-RagoLibraryLock -Seconds 120
        if ($null -eq $lock) { throw 'verrou de la bibliothèque pris (arrêt de Windows en cours ?) : RAGO-LIB pas utilisée' }
        if (Test-RagoShutdownStarted) { throw 'arrêt de Windows commencé : RAGO-LIB pas utilisée' }
        $cfg = Get-RagoAgentConfig
        $comm = Get-RagoCommRoot
        if (-not $comm) { throw 'RAGO-COMM introuvable : RAGO-LIB pas utilisée (Linux ne saurait pas que Windows s''en sert)' }
        $info.comm_root = $comm
        $note = Get-RagoPartitionNoteAny $comm
        $part = Find-RagoLibPartition $note
        if ($null -ne $part -and $null -eq $note) {
            try {
                Write-RagoJson -Path $localNotePath -InputObject ([ordered]@{ schema = 1; kind = 'rago-library-partition'; label = 'RAGO-LIB'; partuuid = ([string]$part.Guid).Trim('{}').ToLowerInvariant(); written_at = (Get-RagoUtcNow); writer = 'rago-agent' })
            } catch { $info.errors += ('library-partition.json : ' + $_.Exception.Message) }
        }
        if ($null -eq $part) {
            $info.lib = [ordered]@{ found = $false; online = $false; offline = $false; error = 'RAGO-LIB introuvable (partition.json absent ou partition absente)' }
            Write-RagoWindowsState -CommRoot $comm -State running -Lib $info.lib -BootId $bootId
            return
        }
        # 1. « running » AVANT la mise en ligne par l'agent. (Si Windows l'a montée
        #    d'office avant, Linux n'est pas actif à ce moment : un seul OS à la fois.)
        $pre = [ordered]@{ found = $true; partuuid = ([string]$part.Guid).Trim('{}').ToLowerInvariant(); online = $false; offline = $false }
        Write-RagoWindowsState -CommRoot $comm -State running -Lib $pre -BootId $bootId
        # 2. mise en ligne sur L: seulement.
        $lib = Mount-RagoLib -Partition $part -Letter ([string]$cfg.lib_letter)
        $info.lib = $lib
        if ($lib.online) {
            # 3. Volume « sale » : réparé avant toute écriture, sinon remis hors ligne.
            $h = Repair-RagoLibIfDirty -Letter ([string]$lib.letter)
            $lib.health = $h
            if (-not $h.ok) {
                $info.errors += ('RAGO-LIB marquée sale et pas réparée ({0}) : remise hors ligne ; à réparer à la main (Gestion des disques : En ligne, puis Propriétés > Outils > Vérifier)' -f $h.repair)
                $lib.online = $false
                $lib.letter = $null
            }
        }
        if ($lib.online) {
            # 4. SYSTEM ne touche dans RAGO-LIB (modifiable par les Utilisateurs) qu'aux
            #    droits de la racine. Arborescence .rago, fiches et métadonnées des
            #    clients : dans la session du joueur, avec les mêmes droits que les clients.
            $root = [string]$lib.letter + ':\'
            $info.lib_root = $root
            try { $lib.acl = Grant-RagoLibUsers -Root $root } catch { $info.errors += ('droits : ' + $_.Exception.Message) }
        }
        Write-RagoWindowsState -CommRoot $comm -State running -Lib $lib -BootId $bootId
    } catch {
        $info.errors += $_.Exception.Message
    } finally {
        if ($null -ne $lock -and -not $info.lib_root) {
            try {
                $c = Close-RagoLibIfOnline $comm
                if ($null -ne $c) {
                    $info.lib_closed = $c
                    if (-not $c.offline) { $info.errors += ('RAGO-LIB peut-être encore montée par Windows : ' + [string]$c.error) }
                }
            } catch { $info.errors += ('mise hors ligne de RAGO-LIB : ' + $_.Exception.Message) }
        }
        Exit-RagoLibraryLock $lock
        # (dans finally : aussi après le « return » de RAGO-LIB introuvable)
        try { $info.vc_runtime = Update-RagoVcRuntime } catch { $info.errors += ('VC++ : ' + $_.Exception.Message) }
        foreach ($e in $info.errors) { Write-RagoLog ('bibliothèque : ' + $e) 'ERROR' }
        Write-RagoJson -Path $bootInfoPath -InputObject $info
    }
}

# --- arrêt (SYSTEM, script d'arrêt) ------------------------------------------------------------------

function Invoke-RagoAgentShutdown {
    Set-RagoLogName 'agent'
    # Marque d'abord : une mise en ligne pas encore commencée n'aura pas lieu.
    try { Write-RagoJson -Path $shutdownMarkPath -InputObject ([ordered]@{ schema = 1; kind = 'rago-library-shutdown'; boot_id = (Get-RagoBootId); at = (Get-RagoUtcNow) }) }
    catch { Write-RagoLog ('library-shutdown.json : ' + $_.Exception.Message) 'ERROR' }
    $lock = Enter-RagoLibraryLock -Seconds 240
    try { Invoke-RagoAgentShutdownLocked -Locked ($null -ne $lock) } finally { Exit-RagoLibraryLock $lock }
}

function Invoke-RagoAgentShutdownLocked {
    param([bool]$Locked)
    $comm = $null
    try { $comm = Get-RagoCommRoot } catch { Write-RagoLog ('RAGO-COMM : ' + $_.Exception.Message) 'ERROR' }
    # found : $null = on ne sait pas (Linux restera en lecture seule). $false
    # SEULEMENT si la recherche a abouti sans erreur ET que ce démarrage n'a
    # jamais mis RAGO-LIB en ligne (library-boot.json de CE démarrage).
    $lib = [ordered]@{ found = $null; online = $false; offline = $false; error = $null }
    try {
        $note = Get-RagoPartitionNoteAny $comm
        $part = Find-RagoLibPartition $note
        if ($null -ne $part) {
            $lib.found = $true
            $lib = Dismount-RagoLib -Partition $part
        } else {
            $boot = Read-RagoBootInfo
            if ($null -eq $boot) { $lib.error = 'RAGO-LIB introuvable à l''arrêt et démarrage de ce Windows inconnu (library-boot.json)' }
            elseif ($boot.lib_root) {
                # En ligne à ce démarrage mais introuvable : au moins la sortir de sa lettre.
                $lib.error = ('RAGO-LIB en ligne à ce démarrage ({0}) mais introuvable à l''arrêt' -f $boot.lib_root)
                $r = Invoke-RagoMountvol @([string]$boot.lib_root, '/P')
                if ($r.code -ne 0) { $lib.error += (' ; mountvol /P : ' + $r.output) }
            }
            else { $lib.found = $false }
        }
    } catch { $lib.error = $_.Exception.Message }
    if (-not $Locked) {
        # Mise en ligne peut-être encore en cours : rien ne prouve que RAGO-LIB reste hors ligne.
        $lib.offline = $false
        $lib.error = (@($lib.error, 'démarrage de la bibliothèque encore en cours (verrou) : mise hors ligne pas sûre') | Where-Object { $_ }) -join ' ; '
    }
    if ($lib.error) { Write-RagoLog ('arrêt : RAGO-LIB : ' + $lib.error) 'ERROR' }
    if (-not $comm) {
        # Linux lira encore « running » : lecture seule, c'est le bon côté du doute.
        Write-RagoLog 'arrêt : RAGO-COMM introuvable, état « off » non écrit' 'ERROR'
        return
    }
    Write-RagoWindowsState -CommRoot $comm -State off -Lib $lib -BootId (Get-RagoBootId)
    Write-RagoLog ('arrêt : « off » écrit (RAGO-LIB hors ligne : {0})' -f $lib.offline)
}

# --- session du joueur --------------------------------------------------------------------------------

function Read-RagoBootInfo {
    $i = $null
    try { $i = Read-RagoJson $bootInfoPath } catch { $i = $null }
    if ($null -eq $i -or -not (Test-RagoProp $i 'boot_id') -or $i.boot_id -ne (Get-RagoBootId)) { return $null }
    return $i
}

function Write-RagoJob {
    param($Comm, $Req, [string]$State, [string]$Message, $Progress = $null, $Prev = $null)
    $started = Get-RagoUtcNow
    if (Get-RagoPropValue $Prev 'started_at') { $started = [string](Get-RagoPropValue $Prev 'started_at') }
    # Rien de neuf : pas de réécriture, SAUF la première fois dans cette session
    # (consigne réaffichée, boot_id et updated_at remis à jour pour Linux).
    $rid = [string]$Req.id
    if ($script:Written.ContainsKey($rid) -and $null -ne $Prev -and [string](Get-RagoPropValue $Prev 'state') -eq $State -and
        [string](Get-RagoPropValue $Prev 'message') -eq $Message -and [string](Get-RagoPropValue $Prev 'progress') -eq [string]$Progress) { return }
    # Abandonnée entre-temps (menu du shell, -Abandon) : on n'écrase pas.
    if ($null -ne $Prev) {
        $now = $null
        try { $now = Read-RagoJson (Join-Path (Get-RagoLibraryCommDir $Comm) ('results\{0}.json' -f $Req.id)) } catch { $now = $null }
        if ([string](Get-RagoPropValue $now 'state') -eq 'cancelled') { return }
    }
    Write-RagoResult -CommRoot $Comm -Request $Req -State $State -Message $Message -Progress $Progress -Extra @{ started_at = $started }
    $script:Written[$rid] = $true
    $color = 'Gray'
    if ($State -eq 'done') { $color = 'Green' } elseif ($State -eq 'failed') { $color = 'Red' } elseif ($State -eq 'waiting_user') { $color = 'Yellow' }
    Write-Host ('[{0}] {1} : {2}' -f $Req.id, $State, $Message) -ForegroundColor $color
}

function Complete-RagoGame {
    param($Comm, $Root, $Req, [string]$InstallDir, [string]$Name, $Size, $ClientIds, [string]$CacheFrom, [string]$CacheName, [string]$Message, $Prev)
    $rel = ConvertTo-RagoLibRelative -Root $Root -Path $InstallDir
    $cache = $null
    if ($CacheFrom -and (Test-Path -LiteralPath $CacheFrom)) {
        $dst = Join-Path $Root ('.rago\cache\{0}\{1}' -f $Req.launcher, $CacheName)
        New-Item -ItemType Directory -Path (Split-Path -Parent $dst) -Force | Out-Null
        Copy-Item -LiteralPath $CacheFrom -Destination $dst -Force
        $cache = ConvertTo-RagoLibRelative -Root $Root -Path $dst
    }
    $old = Read-RagoGameRecord -Root $Root -Key ([string]$Req.game_key)
    $rec = [ordered]@{
        key = [string]$Req.game_key; launcher = [string]$Req.launcher; launcher_id = [string]$Req.launcher_id
        name = $Name; installed = $true; install_dir = $rel; size_bytes = $Size
        installed_at = (Get-RagoUtcNow); installed_by_windows = (Get-RagoWindowsInstallId)
        client_ids = $ClientIds; client_cache = $cache; finalized = $null; last_launch_at = $null
    }
    if ($null -ne $old -and (Test-RagoProp $old 'last_launch_at')) { $rec.last_launch_at = $old.last_launch_at }
    Write-RagoGameRecord -Root $Root -Record $rec
    Write-RagoJob $Comm $Req 'done' $Message 100 $Prev
}

function Set-RagoLaunched {
    param($Root, $Req)
    $g = Read-RagoGameRecord -Root $Root -Key ([string]$Req.game_key)
    if ($null -eq $g) { return }
    $rec = [ordered]@{}
    foreach ($pp in $g.PSObject.Properties) { $rec[$pp.Name] = $pp.Value }
    $rec.last_launch_at = (Get-RagoUtcNow)
    Write-RagoGameRecord -Root $Root -Record $rec
}

# État de la session (une fenêtre -Session par démarrage de Windows).
# Kicked : requêtes pour lesquelles le client a déjà été ouvert dans CETTE
# session. Une requête reprise d'une session précédente (Windows redémarré
# entre-temps) rouvre son client une fois : le shell de Rago n'a pas de bureau
# et ne lance pas les clients au démarrage, leur téléchargement ne reprendrait pas.
$script:Kicked = @{}
$script:ClientTried = @{}   # une seule tentative d'installation de chaque client par session
$script:Strikes = @{}       # erreurs de suite sur une requête en cours
$script:SeenAt = @{}        # première fois que la requête est suivie dans cette session
$script:Written = @{}       # résultats déjà écrits dans cette session

function Test-RagoKick {
    param($Req)
    $rid = [string]$Req.id
    if ($script:Kicked.ContainsKey($rid)) { return $false }
    $script:Kicked[$rid] = $true
    return $true
}

# $true la première fois dans la session (installer le client) ; ensuite $false :
# l'installation a été refusée (contrôle de compte) ou a échoué, on ne la relance pas à chaque tour.
function Test-RagoClientTry {
    param([string]$Name)
    if ($script:ClientTried.ContainsKey($Name)) { return $false }
    $script:ClientTried[$Name] = $true
    return $true
}

# Une étape pour une requête (nouvelle : $Prev = $null ; en cours : dernier résultat).
function Step-RagoRequest {
    param($Comm, $Root, $L, $Req, $Prev)
    $id = [string]$Req.launcher_id
    $key = [string]$Req.launcher + '/' + [string]$Req.action
    $kick = Test-RagoKick $Req
    $noClient = 'client officiel absent : son installation a été refusée ou a échoué pendant cette session (redémarrer Windows pour réessayer)'
    switch ($key) {
        'steam/install' {
            $exe = Get-RagoSteamExe
            if ($null -eq $exe) {
                if (-not (Test-RagoClientTry 'steam')) { Write-RagoJob $Comm $Req 'failed' ('Steam : ' + $noClient) $null $Prev; return }
                Write-RagoJob $Comm $Req 'running' 'installation du client Steam officiel (fenêtre de contrôle de compte)' $null $Prev
                $exe = Install-RagoSteamClient -L $L
            }
            $lib = Join-Path $Root $L.steam.library_dir
            New-Item -ItemType Directory -Path $lib -Force | Out-Null
            $app = Get-RagoSteamApp -LibDir $lib -AppId $id
            if ($null -ne $app -and $app.done) {
                Complete-RagoGame $Comm $Root $Req $app.install_dir $app.name $app.size $null $null $null 'installé sur RAGO-LIB par Steam' $Prev
                return
            }
            if ($null -ne $app) {
                # Reprise (ou client fermé) : Steam reprend sa file de téléchargement à son ouverture.
                if ($kick) { Start-Process -FilePath $exe | Out-Null }
                Write-RagoJob $Comm $Req 'running' 'Steam installe le jeu sur RAGO-LIB' $app.percent $Prev
                return
            }
            $default = Get-RagoSteamApp -LibDir (Split-Path -Parent $exe) -AppId $id
            if ($null -ne $default) {
                Write-RagoJob $Comm $Req 'failed' ('installé dans la bibliothèque de Steam sur C: et non sur RAGO-LIB : le désinstaller puis le réinstaller dans {0}' -f $lib) $null $Prev
                return
            }
            if ($kick) { Start-Process -FilePath $exe -ArgumentList @($L.steam.install_uri.Replace('{id}', $id)) | Out-Null }
            Write-RagoJob $Comm $Req 'waiting_user' ('dans Steam : choisir la bibliothèque {0} (« Ajouter un dossier de bibliothèque » la première fois), puis Installer' -f $lib) $null $Prev
        }
        'steam/launch' {
            $exe = Get-RagoSteamExe
            if ($null -eq $exe) {
                if (-not (Test-RagoClientTry 'steam')) { Write-RagoJob $Comm $Req 'failed' ('Steam : ' + $noClient) $null $Prev; return }
                Write-RagoJob $Comm $Req 'running' 'installation du client Steam officiel (fenêtre de contrôle de compte)' $null $Prev
                $exe = Install-RagoSteamClient -L $L
            }
            $lib = Join-Path $Root $L.steam.library_dir
            $app = Get-RagoSteamApp -LibDir $lib -AppId $id
            if ($null -eq $app -or -not $app.done) { Write-RagoJob $Comm $Req 'failed' 'jeu pas installé sur RAGO-LIB (requête install d''abord)' $null $Prev; return }
            if (-not (Test-RagoSteamLibrary -SteamExe $exe -LibDir $lib)) {
                if ($kick) { Start-Process -FilePath $exe | Out-Null }
                Write-RagoJob $Comm $Req 'waiting_user' ('Steam ne connaît pas encore {0} : Paramètres > Stockage > Ajouter un disque / dossier' -f $lib) $null $Prev
                return
            }
            $a = @($L.steam.launch_args | ForEach-Object { ([string]$_).Replace('{id}', $id) })
            Start-Process -FilePath $exe -ArgumentList $a | Out-Null
            Set-RagoLaunched $Root $Req
            Write-RagoJob $Comm $Req 'done' 'lancé par Steam' $null $Prev
        }
        'epic/install' {
            $exe = Get-RagoEpicExe
            if ($null -eq $exe) {
                if (-not (Test-RagoClientTry 'epic')) { Write-RagoJob $Comm $Req 'failed' ('lanceur Epic : ' + $noClient) $null $Prev; return }
                Write-RagoJob $Comm $Req 'running' 'installation du lanceur Epic officiel (fenêtre de contrôle de compte)' $null $Prev
                $exe = Install-RagoEpicClient -L $L
            }
            $lib = Join-Path $Root $L.epic.library_dir
            New-Item -ItemType Directory -Path $lib -Force | Out-Null
            $app = Get-RagoEpicAppName $id
            $it = Get-RagoEpicItem -L $L -AppName $app
            if ($null -ne $it) {
                $loc = [string]$it.item.InstallLocation
                if (-not (Test-RagoUnder $loc $Root)) {
                    Write-RagoJob $Comm $Req 'failed' ('installé dans {0} et non sur RAGO-LIB : le désinstaller puis le réinstaller dans {1}' -f $loc, $lib) $null $Prev
                    return
                }
                $incomplete = (Test-RagoProp $it.item 'bIsIncompleteInstall') -and [bool]$it.item.bIsIncompleteInstall
                if (-not $incomplete -and (Test-Path -LiteralPath $loc) -and -not (Test-Path -LiteralPath (Join-Path $loc '.egstore\bps'))) {
                    $ids = [ordered]@{ namespace = [string]$it.item.CatalogNamespace; catalog_item_id = [string]$it.item.CatalogItemId; app_name = $app; installation_guid = [string]$it.item.InstallationGuid }
                    Complete-RagoGame $Comm $Root $Req $loc ([string]$it.item.DisplayName) $null $ids $it.file ($app + '.item') 'installé sur RAGO-LIB par le lanceur Epic' $Prev
                    return
                }
                # Reprise (ou lanceur fermé) : rouvrir le lanceur, qui reprend l'installation.
                if ($kick) { Start-Process -FilePath $exe | Out-Null }
                Write-RagoJob $Comm $Req 'running' 'le lanceur Epic installe le jeu sur RAGO-LIB' $null $Prev
                return
            }
            if ($kick) {
                $parts = $id.Split(':')
                if ($parts.Count -eq 3) { $uri = Get-RagoEpicUri -Template $L.epic.install_uri_full -Ns $parts[0] -Cat $parts[1] -App $parts[2] }
                else { $uri = [string]$L.epic.install_uri_library }
                Start-Process -FilePath $uri | Out-Null
            }
            Write-RagoJob $Comm $Req 'waiting_user' ('dans le lanceur Epic : installer {0} dans {1}' -f $app, $lib) $null $Prev
        }
        'epic/launch' {
            $app = Get-RagoEpicAppName $id
            $it = Get-RagoEpicItem -L $L -AppName $app
            if ($null -eq $it -or -not (Test-RagoUnder ([string]$it.item.InstallLocation) $Root)) {
                Write-RagoJob $Comm $Req 'failed' 'jeu inconnu du lanceur Epic sur RAGO-LIB (requête install d''abord)' $null $Prev
                return
            }
            if ($null -eq (Get-RagoEpicExe)) { Write-RagoJob $Comm $Req 'failed' 'lanceur Epic absent (requête install pour le réinstaller)' $null $Prev; return }
            $uri = Get-RagoEpicUri -Template $L.epic.launch_uri -Ns ([string]$it.item.CatalogNamespace) -Cat ([string]$it.item.CatalogItemId) -App $app
            Start-Process -FilePath $uri | Out-Null
            Set-RagoLaunched $Root $Req
            Write-RagoJob $Comm $Req 'done' 'lancé par le lanceur Epic' $null $Prev
        }
        'riot/install' {
            if (-not (Test-RagoProp $L.riot.products $id)) { Write-RagoJob $Comm $Req 'failed' ('produit Riot {0} inconnu (valorant, league_of_legends)' -f $id) $null $Prev; return }
            $lib = Join-Path $Root $L.riot.library_dir
            New-Item -ItemType Directory -Path $lib -Force | Out-Null
            $rc = Get-RagoRiotClientExe -L $L
            $pr = Get-RagoRiotProduct -L $L -Product $id
            if ($null -ne $pr -and $pr.install_dir) {
                if (-not (Test-RagoUnder $pr.install_dir $Root)) {
                    Write-RagoJob $Comm $Req 'failed' ('installé dans {0} et non sur RAGO-LIB : le désinstaller puis le réinstaller dans {1}' -f $pr.install_dir, $lib) $null $Prev
                    return
                }
                if ($pr.done -and $null -ne $rc) {
                    $msg = 'installé sur RAGO-LIB par le Riot Client'
                    if ([bool]$L.riot.products.$id.reboot_after_install) { $msg += ' ; Riot Vanguard peut demander un redémarrage de Windows avant de jouer' }
                    Complete-RagoGame $Comm $Root $Req $pr.install_dir $id $null $null $pr.metadata ('{0}.live.product_settings.yaml' -f $id) $msg $Prev
                    return
                }
                if ($pr.done) {
                    # Jeu sur RAGO-LIB, Riot Client absent (Windows reconstruit) : installateur
                    # officiel, le joueur désigne le dossier existant ; Riot vérifie les fichiers.
                    if ($kick) { Install-RagoRiotClient -L $L -Product $id }
                    Write-RagoJob $Comm $Req 'waiting_user' ('Riot Client à réinstaller : dans l''installateur, Options avancées > dossier {0} (le jeu y est déjà ; Riot devrait vérifier les fichiers plutôt que tout retélécharger, à vérifier)' -f (Split-Path -Parent $pr.install_dir)) $null $Prev
                    return
                }
                # Reprise (ou client fermé) : rouvrir le Riot Client sur le jeu, il reprend la mise à jour.
                if ($kick -and $null -ne $rc) {
                    Start-Process -FilePath $rc -ArgumentList @($L.riot.launch_args | ForEach-Object { ([string]$_).Replace('{id}', $id) }) | Out-Null
                }
                Write-RagoJob $Comm $Req 'running' 'le Riot Client installe le jeu sur RAGO-LIB' $null $Prev
                return
            }
            if ($kick) {
                if ($null -eq $rc) { Install-RagoRiotClient -L $L -Product $id }
                else {
                    $a = @($L.riot.launch_args | ForEach-Object { ([string]$_).Replace('{id}', $id) })
                    Start-Process -FilePath $rc -ArgumentList $a | Out-Null
                }
            }
            Write-RagoJob $Comm $Req 'waiting_user' ('dans la fenêtre de Riot : installer {0} dans {1} (Options avancées / dossier d''installation)' -f $id, $lib) $null $Prev
        }
        'riot/launch' {
            $pr = Get-RagoRiotProduct -L $L -Product $id
            if ($null -eq $pr -or -not $pr.done -or -not (Test-RagoUnder $pr.install_dir $Root)) {
                Write-RagoJob $Comm $Req 'failed' 'jeu Riot pas installé sur RAGO-LIB (requête install d''abord)' $null $Prev
                return
            }
            $rc = Get-RagoRiotClientExe -L $L
            if ($null -eq $rc) { Write-RagoJob $Comm $Req 'failed' 'Riot Client absent (requête install pour le réinstaller)' $null $Prev; return }
            $a = @($L.riot.launch_args | ForEach-Object { ([string]$_).Replace('{id}', $id) })
            Start-Process -FilePath $rc -ArgumentList $a | Out-Null
            Set-RagoLaunched $Root $Req
            Write-RagoJob $Comm $Req 'done' 'lancé par le Riot Client' $null $Prev
        }
        default { Write-RagoJob $Comm $Req 'failed' ('requête {0} inconnue' -f $key) $null $Prev }
    }
}

function Invoke-RagoAgentSession {
    Set-RagoLogName 'agent-session'
    $Host.UI.RawUI.WindowTitle = 'Rago - bibliothèque (M7)'
    $created = $false
    $mutex = New-Object System.Threading.Mutex($true, 'Local\RagoAgentSession', [ref]$created)
    if (-not $created) { Write-Host 'L''agent de la bibliothèque tourne déjà.'; return }
    try {
        $info = Read-RagoBootInfo
        $deadline = (Get-Date).AddSeconds($WaitSeconds)
        if ($null -eq $info -and $WaitSeconds -gt 0) { Write-Host 'Bibliothèque : préparation de RAGO-LIB par le démarrage...' }
        while ($null -eq $info -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2; $info = Read-RagoBootInfo }
        if ($null -eq $info) { Write-Host 'Bibliothèque : le démarrage de ce Windows ne l''a pas préparée (C:\ProgramData\Rago\library-boot.json).' -ForegroundColor Yellow; return }
        if (-not $info.comm_root -or -not $info.lib_root) {
            Write-Host 'Bibliothèque RAGO-LIB indisponible pendant cette session :' -ForegroundColor Yellow
            foreach ($e in @($info.errors)) { Write-Host ('  ! ' + $e) -ForegroundColor Yellow }
            if ((Test-RagoProp $info 'lib') -and $null -ne $info.lib -and (Test-RagoProp $info.lib 'error') -and $info.lib.error) { Write-Host ('  ! ' + $info.lib.error) -ForegroundColor Yellow }
            return
        }
        $comm = [string]$info.comm_root
        $root = [string]$info.lib_root
        $cfg = Get-RagoAgentConfig
        $L = Get-RagoLaunchers
        Write-Host ('Bibliothèque RAGO-LIB : {0}' -f $root) -ForegroundColor Cyan
        # Arborescence et finalisation avec les droits du joueur (jamais en SYSTEM :
        # RAGO-LIB est modifiable par les Utilisateurs).
        try { Initialize-RagoLibTree -Root $root } catch { Write-RagoLog ('.rago : ' + $_.Exception.Message) 'WARN' }
        try { Invoke-RagoFinalize -Root $root } catch { Write-RagoLog ('finalisation : ' + $_.Exception.Message) 'WARN' }
        while ($true) {
            foreach ($req in @(Get-RagoRequests -CommRoot $comm)) {
                # La requête passe dans results\ : Linux ne peut plus l'annuler (Windows l'a prise).
                Remove-Item -LiteralPath (Join-Path (Get-RagoLibraryCommDir $comm) ('requests\{0}.json' -f $req.id)) -Force
                try { Step-RagoRequest $comm $root $L $req $null }
                catch { Write-RagoJob $comm $req 'failed' $_.Exception.Message $null $null; Write-RagoLog ('{0} : {1}' -f $req.id, $_.Exception.Message) 'ERROR' }
            }
            $open = @(Get-RagoOpenResults -CommRoot $comm)
            if ($open.Count -eq 0) { break }
            foreach ($res in $open) {
                $rid = [string]$res.id
                # Délai compté dans CETTE session de Windows (le temps passé sous
                # Linux ne compte pas) ; la requête a toujours au moins une étape.
                $now = (Get-Date).ToUniversalTime()
                if (-not $script:SeenAt.ContainsKey($rid)) { $script:SeenAt[$rid] = $now }
                elseif (($now - $script:SeenAt[$rid]).TotalHours -gt [double]$cfg.job_timeout_hours) {
                    Write-RagoJob $comm $res 'failed' ('sans fin après {0} h dans cette session de Windows : abandonné' -f $cfg.job_timeout_hours) $null $res
                    continue
                }
                try {
                    Step-RagoRequest $comm $root $L $res $res
                    $script:Strikes.Remove($rid)
                } catch {
                    $n = 1
                    if ($script:Strikes.ContainsKey($rid)) { $n = [int]$script:Strikes[$rid] + 1 }
                    $script:Strikes[$rid] = $n
                    Write-RagoLog ('{0} : {1} (erreur {2}/3)' -f $rid, $_.Exception.Message, $n) 'WARN'
                    # Trois erreurs de suite : échec (pas de boucle de téléchargements ou de fenêtres).
                    if ($n -ge 3) { Write-RagoJob $comm $res 'failed' $_.Exception.Message $null $res }
                }
            }
            Start-Sleep -Seconds ([int]$cfg.poll_seconds)
        }
        Write-Host 'Bibliothèque : plus rien en cours.' -ForegroundColor Green
    } finally {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

function Show-RagoAgentStatus {
    $info = Read-RagoBootInfo
    if ($null -eq $info) { Write-Host 'Bibliothèque : pas préparée par ce démarrage.'; return }
    if ($info.lib_root) { Write-Host ('RAGO-LIB : {0} (en ligne)' -f $info.lib_root) -ForegroundColor Green }
    else {
        $closed = $null
        if (Test-RagoProp $info 'lib_closed') { $closed = $info.lib_closed }
        if ($null -ne $closed -and (Test-RagoProp $closed 'offline') -and $closed.offline) { Write-Host 'RAGO-LIB : pas utilisée pendant cette session (hors ligne, confirmé par Windows)' -ForegroundColor Yellow }
        else { Write-Host 'RAGO-LIB : pas utilisée pendant cette session (mise hors ligne pas confirmée)' -ForegroundColor Yellow }
    }
    foreach ($e in @($info.errors)) { Write-Host ('  ! ' + $e) -ForegroundColor Yellow }
    if ($null -ne $info.shutdown_script -and (Test-RagoProp $info.shutdown_script 'registered') -and -not $info.shutdown_script.registered) {
        Write-Host '  script d''arrêt pas encore actif (Windows le prend au démarrage suivant) : Linux restera en lecture seule après cet arrêt' -ForegroundColor Yellow
    }
    if (-not $info.comm_root) { return }
    $dir = Join-Path (Get-RagoLibraryCommDir ([string]$info.comm_root)) 'results'
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        try { $r = Read-RagoJson $f.FullName } catch { continue }
        Write-Host ('  {0}  {1}  {2}' -f (Get-RagoPropValue $r 'id'), (Get-RagoPropValue $r 'state'), (Get-RagoPropValue $r 'message'))
    }
    $pending = @(Get-RagoRequests -CommRoot ([string]$info.comm_root))
    if ($pending.Count -gt 0) { Write-Host ('  {0} requête(s) de Linux pas encore prise(s)' -f $pending.Count) }
}

function Invoke-RagoAbandon {
    param([string]$Id)
    Set-RagoLogName 'agent-session'
    if (-not ($Id -cmatch '^(install|launch)-(steam|epic|riot)-[a-z0-9-]{1,80}$')) { throw ('requête {0} refusée' -f $Id) }
    $info = Read-RagoBootInfo
    if ($null -eq $info -or -not $info.comm_root) { throw 'RAGO-COMM indisponible' }
    $p = Join-Path (Get-RagoLibraryCommDir ([string]$info.comm_root)) ('results\{0}.json' -f $Id)
    $r = Read-RagoJson $p
    if ($null -eq $r) { throw ('pas de résultat {0}' -f $Id) }
    Write-RagoResult -CommRoot ([string]$info.comm_root) -Request $r -State cancelled -Message 'abandonnée par le joueur (menu du shell)'
    Write-Host ('{0} : abandonnée' -f $Id)
}

if ($Boot) { Invoke-RagoAgentBoot; exit 0 }
if ($Shutdown) {
    try { Invoke-RagoAgentShutdown } catch { Write-RagoLog ('arrêt : ' + $_.Exception.Message) 'ERROR' }
    exit 0
}
if ($RegisterShutdown) {
    Set-RagoLogName 'agent'
    $r = Set-RagoShutdownScript
    Write-Output ('script d''arrêt : fichiers modifiés {0}, actif {1}' -f $r.files_changed, $r.registered)
    exit 0
}
if ($Session) {
    Import-Module (Join-Path $PSScriptRoot 'RagoLaunchers.psm1') -Force
    Invoke-RagoAgentSession
    exit 0
}
if ($Abandon) { Invoke-RagoAbandon -Id $Abandon; exit 0 }
if ($Status) { Show-RagoAgentStatus; exit 0 }
Write-Output 'usage : rago-agent.ps1 -Boot | -Shutdown | -Session | -Status | -Abandon ID | -RegisterShutdown'
exit 2
