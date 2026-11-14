# SPDX-License-Identifier: GPL-2.0
#
# Rago OS - bibliothèque partagée (module M7) : les clients OFFICIELS des
# boutiques (Steam, Epic Games Launcher, Riot Client), côté Windows, dans la
# session du joueur. C:\Rago\agent\RagoLaunchers.psm1.
#
# Jamais exécuté à ce jour (Windows, conteneur Linux) : validé seulement par
# lecture (windows/tests/test_agent.py). Les adresses, chemins et formats
# viennent de launchers.json, avec leurs sources ; ceux qui ne sont pas
# documentés par l'éditeur sont marqués « À VÉRIFIER » dans la note M7 du vault.
#
# Principe : l'installation d'un jeu passe TOUJOURS par le client officiel,
# dans Windows ; l'agent ouvre la bonne page du client (le joueur confirme et
# choisit le dossier sur RAGO-LIB), puis suit les fichiers que le client écrit
# pour savoir quand c'est fini. Les prérequis (VC++, DirectX, .NET) et les
# clés de registre d'un jeu sont posés par le client lui-même (scripts
# d'installation de Steam au premier lancement, prérequis du lanceur Epic à
# l'installation). Aucune dissimulation, aucune copie de client.

Set-StrictMode -Version 2.0

# --- outils ---------------------------------------------------------------------------------------

function Expand-RagoPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [Environment]::ExpandEnvironmentVariables($Path)
}

function Get-RagoRegValue {
    param([string]$Key, [string]$Name)
    try { return [string](Get-ItemProperty -LiteralPath $Key -Name $Name -ErrorAction Stop).$Name } catch { return $null }
}

# Télécharge l'installateur officiel et vérifie sa signature Authenticode.
function Get-RagoOfficialInstaller {
    param([Parameter(Mandatory = $true)][string]$Url, [Parameter(Mandatory = $true)][string]$SignerRx, [Parameter(Mandatory = $true)][string]$FileName)
    if (-not ($Url -match '^https://')) { throw ('adresse refusée (https seulement) : ' + $Url) }
    $dir = Join-Path $env:TEMP 'rago-agent'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $dst = Join-Path $dir $FileName
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $old = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try { Invoke-WebRequest -Uri $Url -OutFile $dst -UseBasicParsing -TimeoutSec 600 } finally { $ProgressPreference = $old }
    $sig = Get-AuthenticodeSignature -LiteralPath $dst
    $subject = ''
    if ($null -ne $sig.SignerCertificate) { $subject = [string]$sig.SignerCertificate.Subject }
    if ($sig.Status -ne 'Valid' -or -not ($subject -match $SignerRx)) {
        Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
        throw ('signature de {0} refusée (état {1}, signataire « {2} », attendu {3})' -f $FileName, $sig.Status, $subject, $SignerRx)
    }
    Write-RagoLog ('{0} téléchargé depuis {1}, signé par {2}' -f $FileName, $Url, $subject)
    return $dst
}

# Lance un programme en administrateur (fenêtre UAC pour le joueur) et attend.
function Invoke-RagoElevated {
    param([Parameter(Mandatory = $true)][string]$FilePath, [string[]]$Arguments = @(), [int[]]$OkCodes = @(0))
    if ($Arguments.Count -gt 0) { $p = Start-Process -FilePath $FilePath -ArgumentList $Arguments -Verb RunAs -PassThru -Wait }
    else { $p = Start-Process -FilePath $FilePath -Verb RunAs -PassThru -Wait }
    if ($OkCodes -notcontains $p.ExitCode) { throw ('{0} : code {1}' -f (Split-Path -Leaf $FilePath), $p.ExitCode) }
    return $p.ExitCode
}

# Valeurs « clé » « valeur » d'un fichier VDF de Steam (premier niveau utile ici).
function Read-RagoVdfValues {
    param([Parameter(Mandatory = $true)][string]$Path)
    $h = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    foreach ($m in [regex]::Matches([System.IO.File]::ReadAllText($Path), '"([^"]+)"[ \t]+"((?:[^"\\]|\\.)*)"')) {
        $k = $m.Groups[1].Value
        if (-not $h.ContainsKey($k)) { $h[$k] = $m.Groups[2].Value.Replace('\\', '\') }
    }
    return $h
}

function Test-RagoUnder {
    param([string]$Path, [string]$Root)
    if (-not $Path -or -not $Root) { return $false }
    try {
        $f = [System.IO.Path]::GetFullPath($Path.Replace('/', '\')).TrimEnd('\') + '\'
        $r = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
        return $f.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

# --- Steam -----------------------------------------------------------------------------------------

function Get-RagoSteamExe {
    $c = @()
    $v = Get-RagoRegValue 'HKCU:\Software\Valve\Steam' 'SteamExe'
    if ($v) { $c += $v.Replace('/', '\') }
    $v = Get-RagoRegValue 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' 'InstallPath'
    if ($v) { $c += (Join-Path $v 'steam.exe') }
    $c += (Join-Path ${env:ProgramFiles(x86)} 'Steam\steam.exe')
    foreach ($x in $c) { if ($x -and (Test-Path -LiteralPath $x)) { return $x } }
    return $null
}

function Install-RagoSteamClient {
    param([Parameter(Mandatory = $true)]$L)
    $f = Get-RagoOfficialInstaller -Url $L.steam.installer_url -SignerRx $L.steam.signer_rx -FileName 'SteamSetup.exe'
    # NSIS : /S silencieux, dossier par défaut (C:\Program Files (x86)\Steam).
    [void](Invoke-RagoElevated -FilePath $f -Arguments @('/S'))
    $exe = Get-RagoSteamExe
    if ($null -eq $exe) { throw 'Steam installé mais steam.exe introuvable' }
    return $exe
}

# La bibliothèque L:\Games\Steam est-elle connue de Steam ?
function Test-RagoSteamLibrary {
    param([Parameter(Mandatory = $true)][string]$SteamExe, [Parameter(Mandatory = $true)][string]$LibDir)
    $want = [System.IO.Path]::GetFullPath($LibDir).TrimEnd('\')
    foreach ($rel in @('config\libraryfolders.vdf', 'steamapps\libraryfolders.vdf')) {
        $f = Join-Path (Split-Path -Parent $SteamExe) $rel
        if (-not (Test-Path -LiteralPath $f)) { continue }
        foreach ($m in [regex]::Matches([System.IO.File]::ReadAllText($f), '"path"[ \t]+"((?:[^"\\]|\\.)*)"')) {
            $p = $m.Groups[1].Value.Replace('\\', '\').TrimEnd('\')
            if ([string]::Equals($p, $want, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
    }
    return $false
}

# État d'un jeu Steam dans une bibliothèque : $null (pas de manifeste) ou détails.
function Get-RagoSteamApp {
    param([Parameter(Mandatory = $true)][string]$LibDir, [Parameter(Mandatory = $true)][string]$AppId)
    $acf = Join-Path $LibDir ('steamapps\appmanifest_{0}.acf' -f $AppId)
    $v = Read-RagoVdfValues $acf
    if ($null -eq $v -or -not $v.ContainsKey('StateFlags')) { return $null }
    $flags = [int64]$v['StateFlags']
    # Bits de StateFlags (relevés par game-scanner / LinuxGSM, pas publiés par Valve) :
    # 4 installé ; 2 mise à jour requise ; 256 / 1024 mise à jour en cours / commencée ;
    # 1048576 téléchargement ; 2097152 / 4194304 mise en place.
    $busy = 2 -bor 256 -bor 1024 -bor 1048576 -bor 2097152 -bor 4194304
    $done = (($flags -band 4) -eq 4) -and (($flags -band $busy) -eq 0)
    $pct = $null
    if ($v.ContainsKey('BytesToDownload') -and [int64]$v['BytesToDownload'] -gt 0) {
        $pct = [math]::Round(100.0 * [int64]$v['BytesDownloaded'] / [int64]$v['BytesToDownload'], 1)
    }
    $dir = $null
    if ($v.ContainsKey('installdir')) { $dir = Join-Path $LibDir ('steamapps\common\' + $v['installdir']) }
    $name = $null
    if ($v.ContainsKey('name')) { $name = $v['name'] }
    $size = $null
    if ($v.ContainsKey('SizeOnDisk')) { $size = [int64]$v['SizeOnDisk'] }
    return [pscustomobject]@{ manifest = $acf; flags = $flags; done = $done; percent = $pct; install_dir = $dir; name = $name; size = $size }
}

# --- Epic Games Launcher ---------------------------------------------------------------------------

function Get-RagoEpicExe {
    $roots = @()
    foreach ($k in @('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        foreach ($e in @(Get-ItemProperty -Path $k -ErrorAction SilentlyContinue)) {
            if ($e.PSObject.Properties.Name -contains 'DisplayName' -and [string]$e.DisplayName -eq 'Epic Games Launcher' -and
                $e.PSObject.Properties.Name -contains 'InstallLocation' -and $e.InstallLocation) { $roots += [string]$e.InstallLocation }
        }
    }
    $roots += (Join-Path ${env:ProgramFiles(x86)} 'Epic Games')
    $roots += (Join-Path $env:ProgramFiles 'Epic Games')
    foreach ($r in $roots) {
        foreach ($arch in @('Win32', 'Win64')) {
            $x = Join-Path $r ('Launcher\Portal\Binaries\{0}\EpicGamesLauncher.exe' -f $arch)
            if (Test-Path -LiteralPath $x) { return $x }
        }
    }
    return $null
}

function Install-RagoEpicClient {
    param([Parameter(Mandatory = $true)]$L)
    $f = Get-RagoOfficialInstaller -Url $L.epic.installer_url -SignerRx $L.epic.signer_rx -FileName 'EpicInstaller.msi'
    # msiexec /i : méthode décrite par l'aide d'Epic ; /qn /norestart : MSI WiX.
    [void](Invoke-RagoElevated -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -Arguments @('/i', ('"{0}"' -f $f), '/qn', '/norestart') -OkCodes @(0, 3010, 1641))
    $exe = Get-RagoEpicExe
    if ($null -eq $exe) { throw 'lanceur Epic installé mais EpicGamesLauncher.exe introuvable' }
    return $exe
}

# AppName d'un identifiant Epic (« AppName » ou « espace:article:AppName »).
function Get-RagoEpicAppName {
    param([Parameter(Mandatory = $true)][string]$Id)
    return ($Id.Split(':')[-1])
}

# Manifeste .item du lanceur pour ce jeu (le jeu principal, pas un DLC).
function Get-RagoEpicItem {
    param([Parameter(Mandatory = $true)]$L, [Parameter(Mandatory = $true)][string]$AppName)
    $dir = Expand-RagoPath $L.epic.manifests_dir
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.item' -File -ErrorAction SilentlyContinue)) {
        $j = $null
        try { $j = Read-RagoJson $f.FullName } catch { continue }
        if ($null -eq $j -or -not ($j.PSObject.Properties.Name -contains 'AppName')) { continue }
        if ([string]$j.AppName -ne $AppName) { continue }
        if ($j.PSObject.Properties.Name -contains 'MainGameAppName' -and $j.MainGameAppName -and [string]$j.MainGameAppName -ne $AppName) { continue }
        return [pscustomobject]@{ file = $f.FullName; item = $j }
    }
    return $null
}

function Get-RagoEpicUri {
    param([Parameter(Mandatory = $true)][string]$Template, [Parameter(Mandatory = $true)][string]$Ns, [Parameter(Mandatory = $true)][string]$Cat, [Parameter(Mandatory = $true)][string]$App)
    return $Template.Replace('{ns}', [uri]::EscapeDataString($Ns)).Replace('{cat}', [uri]::EscapeDataString($Cat)).Replace('{app}', [uri]::EscapeDataString($App))
}

# --- Riot Client -----------------------------------------------------------------------------------

function Get-RagoRiotClientExe {
    param([Parameter(Mandatory = $true)]$L)
    $installs = Expand-RagoPath $L.riot.client_installs_json
    if (Test-Path -LiteralPath $installs) {
        try {
            $j = Read-RagoJson $installs
            foreach ($n in @('rc_default', 'rc_live')) {
                if ($j.PSObject.Properties.Name -contains $n -and $j.$n) {
                    $x = ([string]$j.$n).Replace('/', '\')
                    if (Test-Path -LiteralPath $x) { return $x }
                }
            }
        } catch { Write-RagoLog ('RiotClientInstalls.json : ' + $_.Exception.Message) 'WARN' }
    }
    $x = Expand-RagoPath $L.riot.client_default
    if (Test-Path -LiteralPath $x) { return $x }
    return $null
}

# Dossier d'installation d'un produit Riot, lu dans ses métadonnées (YAML).
function Get-RagoRiotProduct {
    param([Parameter(Mandatory = $true)]$L, [Parameter(Mandatory = $true)][string]$Product)
    $meta = Join-Path (Expand-RagoPath $L.riot.metadata_dir) ('{0}.live\{0}.live.product_settings.yaml' -f $Product)
    if (-not (Test-Path -LiteralPath $meta)) { return $null }
    $path = $null
    foreach ($line in [System.IO.File]::ReadAllLines($meta)) {
        if ($line -match '^\s*product_install_full_path:\s*"?([^"]*)"?\s*$') { $path = $Matches[1].Replace('/', '\') }
    }
    if (-not $path) { return [pscustomobject]@{ metadata = $meta; install_dir = $null; done = $false } }
    $exeOk = $false
    $p = $null
    if ($L.riot.products.PSObject.Properties.Name -contains $Product) { $p = $L.riot.products.$Product }
    if ($null -ne $p) {
        foreach ($rel in @($p.main_files)) { if (Test-Path -LiteralPath (Join-Path $path $rel)) { $exeOk = $true } }
    }
    return [pscustomobject]@{ metadata = $meta; install_dir = $path; done = $exeOk }
}

function Install-RagoRiotClient {
    param([Parameter(Mandatory = $true)]$L, [Parameter(Mandatory = $true)][string]$Product)
    if (-not ($L.riot.products.PSObject.Properties.Name -contains $Product)) { throw ('produit Riot {0} inconnu de launchers.json' -f $Product) }
    $p = $L.riot.products.$Product
    $f = Get-RagoOfficialInstaller -Url $p.installer_url -SignerRx $L.riot.signer_rx -FileName ('Install {0}.exe' -f $Product)
    # Installateur officiel du jeu : installe le Riot Client puis le jeu ; le joueur
    # choisit le dossier (L:\Games\Riot) dans sa fenêtre. Pas d'option silencieuse documentée.
    Start-Process -FilePath $f | Out-Null
}

Export-ModuleMember -Function Expand-RagoPath, Get-RagoRegValue, Get-RagoOfficialInstaller, Invoke-RagoElevated, Read-RagoVdfValues,
    Test-RagoUnder, Get-RagoSteamExe, Install-RagoSteamClient, Test-RagoSteamLibrary, Get-RagoSteamApp, Get-RagoEpicExe,
    Install-RagoEpicClient, Get-RagoEpicAppName, Get-RagoEpicItem, Get-RagoEpicUri, Get-RagoRiotClientExe, Get-RagoRiotProduct,
    Install-RagoRiotClient
