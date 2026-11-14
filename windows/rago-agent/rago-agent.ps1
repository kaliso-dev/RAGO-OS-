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
                  Linux) ; sans RAGO-COMM, RAGO-LIB reste hors ligne ;
               3. droits d'écriture des clients, arborescence .rago\ ;
               4. finalise les jeux sur CETTE installation de Windows
                  (VC++ fourni par le joueur dans C:\Rago\redist s'il manque,
                  métadonnées des clients remises depuis RAGO-LIB\.rago\cache) ;
               5. note la session dans C:\ProgramData\Rago\library-boot.json.
    -Shutdown  (compte SYSTEM, script d'arrêt de la stratégie locale) : vide
               le cache de RAGO-LIB, la met hors ligne (mountvol /P), puis
               écrit « off » (avec lib.offline) dans RAGO-COMM.
    -Session   (compte du joueur, lancé par rago-shell.ps1) : prend les
               requêtes de Linux (RAGO-COMM\library\requests), ouvre le client
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
    return ('remis : ' + $To)
}

function Invoke-RagoFinalize {
    param([Parameter(Mandatory = $true)][string]$Root)
    $wid = Get-RagoWindowsInstallId
    $L = Get-RagoLaunchers
    $vcChecked = $null
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $Root '.rago\games') -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $g = $null
        try { $g = Read-RagoJson $f.FullName } catch { Write-RagoLog ('fiche illisible {0}' -f $f.Name) 'WARN'; continue }
        if ($null -eq $g -or -not (Test-RagoProp $g 'key') -or ($f.Name -ne ([string]$g.key + '.json'))) { continue }
        if (-not (Test-RagoProp $g 'installed') -or -not $g.installed) { continue }
        if ((Test-RagoProp $g 'finalized') -and $null -ne $g.finalized -and (Test-RagoProp $g.finalized 'windows_install_id') -and
            [string]$g.finalized.windows_install_id -eq $wid) { continue }
        $steps = [ordered]@{}
        if ($null -eq $vcChecked) {
            $vcChecked = 'présent'
            if (-not (Test-RagoVcRuntime)) {
                $r = @(Install-RagoVcFromRedist)
                if ($r.Count -eq 0) { $vcChecked = 'absent (ni dans Windows ni dans C:\Rago\redist) : le client l''installera au besoin' }
                else { $vcChecked = ($r -join ' ; ') }
            }
        }
        $steps.vc_runtime = $vcChecked
        $cache = Join-Path $Root '.rago\cache'
        switch ([string]$g.launcher) {
            'steam' { $steps.client = 'Steam refait lui-même la préparation du jeu (scripts d''installation) au premier lancement' }
            'epic' {
                $app = Get-RagoEpicAppNameLocal ([string]$g.launcher_id)
                $guid = [string](Get-RagoPropValue (Get-RagoPropValue $g 'client_ids') 'installation_guid')
                if ($guid -match '^[0-9A-Fa-f]{32}$') {
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

function Invoke-RagoAgentBoot {
    Set-RagoLogName 'agent'
    $bootId = Get-RagoBootId
    $info = [ordered]@{ schema = 1; kind = 'rago-library-boot'; boot_id = $bootId; written_at = (Get-RagoUtcNow); comm_root = $null; lib_root = $null; lib = $null; shutdown_script = $null; errors = @() }
    try { $info.shutdown_script = Set-RagoShutdownScript } catch { $info.errors += ('script d''arrêt : ' + $_.Exception.Message) }
    try {
        $cfg = Get-RagoAgentConfig
        $comm = Get-RagoCommRoot
        if (-not $comm) { throw 'RAGO-COMM introuvable : RAGO-LIB reste hors ligne (Linux ne saurait pas que Windows s''en sert)' }
        $info.comm_root = $comm
        $note = Read-RagoPartitionNote $comm
        $part = Find-RagoLibPartition $note
        if ($null -eq $part) {
            $info.lib = [ordered]@{ found = $false; online = $false; offline = $false; error = 'RAGO-LIB introuvable (partition.json absent ou partition absente)' }
            Write-RagoWindowsState -CommRoot $comm -State running -Lib $info.lib -BootId $bootId
            return
        }
        # 1. « running » AVANT la mise en ligne.
        $pre = [ordered]@{ found = $true; partuuid = ([string]$part.Guid).Trim('{}').ToLowerInvariant(); online = $false; offline = $false }
        Write-RagoWindowsState -CommRoot $comm -State running -Lib $pre -BootId $bootId
        # 2. mise en ligne.
        $lib = Mount-RagoLib -Partition $part -Letter ([string]$cfg.lib_letter)
        $info.lib = $lib
        if ($lib.online) {
            $root = [string]$lib.letter + ':\'
            $info.lib_root = $root
            try { Initialize-RagoLibTree -Root $root } catch { $info.errors += ('.rago : ' + $_.Exception.Message) }
            try { $lib.acl = Grant-RagoLibUsers -Root $root } catch { $info.errors += ('droits : ' + $_.Exception.Message) }
            try { Invoke-RagoFinalize -Root $root } catch { $info.errors += ('finalisation : ' + $_.Exception.Message) }
        }
        Write-RagoWindowsState -CommRoot $comm -State running -Lib $lib -BootId $bootId
    } catch {
        $info.errors += $_.Exception.Message
    } finally {
        foreach ($e in $info.errors) { Write-RagoLog ('bibliothèque : ' + $e) 'ERROR' }
        Write-RagoJson -Path $bootInfoPath -InputObject $info
    }
}

# --- arrêt (SYSTEM, script d'arrêt) ------------------------------------------------------------------

function Invoke-RagoAgentShutdown {
    Set-RagoLogName 'agent'
    $comm = $null
    try { $comm = Get-RagoCommRoot } catch { Write-RagoLog ('RAGO-COMM : ' + $_.Exception.Message) 'ERROR' }
    $lib = [ordered]@{ found = $false; online = $false; offline = $false; error = $null }
    try {
        $note = $null
        if ($comm) { $note = Read-RagoPartitionNote $comm }
        $part = Find-RagoLibPartition $note
        if ($null -ne $part) { $lib = Dismount-RagoLib -Partition $part }
    } catch { $lib.error = $_.Exception.Message }
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
    if ($null -ne $Prev -and [string](Get-RagoPropValue $Prev 'state') -eq $State -and [string](Get-RagoPropValue $Prev 'message') -eq $Message -and
        [string](Get-RagoPropValue $Prev 'progress') -eq [string]$Progress) { return }
    # Abandonnée entre-temps (menu du shell, -Abandon) : on n'écrase pas.
    if ($null -ne $Prev) {
        $now = $null
        try { $now = Read-RagoJson (Join-Path (Get-RagoLibraryCommDir $Comm) ('results\{0}.json' -f $Req.id)) } catch { $now = $null }
        if ([string](Get-RagoPropValue $now 'state') -eq 'cancelled') { return }
    }
    Write-RagoResult -CommRoot $Comm -Request $Req -State $State -Message $Message -Progress $Progress -Extra @{ started_at = $started }
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

# Une étape pour une requête (nouvelle : $Prev = $null ; en cours : dernier résultat).
function Step-RagoRequest {
    param($Comm, $Root, $L, $Req, $Prev)
    $id = [string]$Req.launcher_id
    $key = [string]$Req.launcher + '/' + [string]$Req.action
    switch ($key) {
        'steam/install' {
            $exe = Get-RagoSteamExe
            if ($null -eq $exe) {
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
            if ($null -ne $app) { Write-RagoJob $Comm $Req 'running' 'Steam installe le jeu sur RAGO-LIB' $app.percent $Prev; return }
            $default = Get-RagoSteamApp -LibDir (Split-Path -Parent $exe) -AppId $id
            if ($null -ne $default) {
                Write-RagoJob $Comm $Req 'failed' ('installé dans la bibliothèque de Steam sur C: et non sur RAGO-LIB : le désinstaller puis le réinstaller dans {0}' -f $lib) $null $Prev
                return
            }
            if ($null -eq $Prev) { Start-Process -FilePath $exe -ArgumentList @($L.steam.install_uri.Replace('{id}', $id)) | Out-Null }
            Write-RagoJob $Comm $Req 'waiting_user' ('dans Steam : choisir la bibliothèque {0} (« Ajouter un dossier de bibliothèque » la première fois), puis Installer' -f $lib) $null $Prev
        }
        'steam/launch' {
            $exe = Get-RagoSteamExe
            if ($null -eq $exe) {
                Write-RagoJob $Comm $Req 'running' 'installation du client Steam officiel (fenêtre de contrôle de compte)' $null $Prev
                $exe = Install-RagoSteamClient -L $L
            }
            $lib = Join-Path $Root $L.steam.library_dir
            $app = Get-RagoSteamApp -LibDir $lib -AppId $id
            if ($null -eq $app -or -not $app.done) { Write-RagoJob $Comm $Req 'failed' 'jeu pas installé sur RAGO-LIB (requête install d''abord)' $null $Prev; return }
            if (-not (Test-RagoSteamLibrary -SteamExe $exe -LibDir $lib)) {
                if ($null -eq $Prev) { Start-Process -FilePath $exe | Out-Null }
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
                Write-RagoJob $Comm $Req 'running' 'le lanceur Epic installe le jeu sur RAGO-LIB' $null $Prev
                return
            }
            if ($null -eq $Prev) {
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
                    if ($null -eq $Prev) { Install-RagoRiotClient -L $L -Product $id }
                    Write-RagoJob $Comm $Req 'waiting_user' ('Riot Client à réinstaller : dans l''installateur, Options avancées > dossier {0} (le jeu y est déjà, Riot vérifie les fichiers)' -f (Split-Path -Parent $pr.install_dir)) $null $Prev
                    return
                }
                Write-RagoJob $Comm $Req 'running' 'le Riot Client installe le jeu sur RAGO-LIB' $null $Prev
                return
            }
            if ($null -eq $Prev) {
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
                $started = $null
                $s = [string](Get-RagoPropValue $res 'started_at')
                if ($s) {
                    try { $started = [datetime]::Parse($s, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() } catch { $started = $null }
                }
                if ($null -ne $started -and ((Get-Date).ToUniversalTime() - $started).TotalHours -gt [double]$cfg.job_timeout_hours) {
                    Write-RagoJob $comm $res 'failed' ('sans fin après {0} h : abandonné' -f $cfg.job_timeout_hours) $null $res
                    continue
                }
                try { Step-RagoRequest $comm $root $L $res $res }
                catch { Write-RagoLog ('{0} : {1}' -f $res.id, $_.Exception.Message) 'WARN' }
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
    else { Write-Host 'RAGO-LIB : hors ligne pendant cette session' -ForegroundColor Yellow }
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
