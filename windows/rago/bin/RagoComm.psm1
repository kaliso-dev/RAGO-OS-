# SPDX-License-Identifier: GPL-2.0
#
# Rago OS - fonctions communes du micro-Windows (module M5).
#
# Installé dans C:\Rago\bin\RagoComm.psm1. Utilisé par rago-boot.ps1,
# rago-security.ps1, rago-report.ps1 et rago-shell.ps1.
#
#   - journal : C:\ProgramData\Rago\logs\<nom>.log (compte SYSTEM),
#     %LOCALAPPDATA%\Rago\logs\<nom>.log (session du joueur : shell)
#   - JSON sans marque BOM (Linux le lit tel quel), écrit par fichier temporaire
#   - partition d'échange RAGO-COMM (FAT32, étiquette RAGO-COMM) : trouvée par
#     son étiquette ; si Windows ne lui a pas donné de lettre, elle est montée
#     dans le dossier C:\Rago\comm
#
# Windows PowerShell 5.1 (celui de Windows) : pas de syntaxe propre à PowerShell 7.

Set-StrictMode -Version 2.0

$script:RagoRoot    = Join-Path $env:SystemDrive 'Rago'
$script:RagoData    = Join-Path $env:ProgramData 'Rago'
$script:RagoLogDir  = Join-Path $script:RagoData 'logs'
# C:\ProgramData\Rago n'est modifiable que par SYSTEM et les Administrateurs
# (firstboot.ps1) : le shell, lancé dans la session du joueur, journalise chez lui.
$me = [System.Security.Principal.WindowsIdentity]::GetCurrent()
if ($me.User.Value -ne 'S-1-5-18' -and $env:LOCALAPPDATA) { $script:RagoLogDir = Join-Path $env:LOCALAPPDATA 'Rago\logs' }
$script:CommLabel   = 'RAGO-COMM'
$script:CommMountAt = Join-Path $script:RagoRoot 'comm'
$script:LogName     = 'rago'

function Get-RagoDataDir { return $script:RagoData }
function Get-RagoRootDir { return $script:RagoRoot }

function Set-RagoLogName {
    param([Parameter(Mandatory = $true)][string]$Name)
    $script:LogName = $Name
}

function Write-RagoLog {
    param([Parameter(Mandatory = $true)][string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')
    $line = '{0} {1} {2}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'), $Level, $Message
    try {
        if (-not (Test-Path -LiteralPath $script:RagoLogDir)) {
            New-Item -ItemType Directory -Path $script:RagoLogDir -Force | Out-Null
        }
        Add-Content -LiteralPath (Join-Path $script:RagoLogDir ($script:LogName + '.log')) -Value $line -Encoding UTF8
    } catch {
        # Le journal ne doit jamais faire échouer le démarrage.
    }
    Write-Verbose $line
}

function Get-RagoUtcNow { return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }

# Identité du démarrage en cours : heure de démarrage du noyau, en UTC.
function Get-RagoBootId {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    return $os.LastBootUpTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function ConvertTo-RagoJson {
    param([Parameter(Mandatory = $true)]$InputObject)
    # -Depth : sans lui, Windows PowerShell 5.1 coupe les objets imbriqués au 2e niveau.
    return ($InputObject | ConvertTo-Json -Depth 12)
}

# Écrit du JSON en UTF-8 SANS BOM : fichier temporaire puis remplacement.
function Write-RagoJson {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$InputObject)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = $Path + '.tmp'
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmp, (ConvertTo-RagoJson $InputObject) + "`n", $utf8)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# Lit un fichier JSON ; $null s'il manque ; lève une erreur s'il est illisible.
function Read-RagoJson {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $text = [System.IO.File]::ReadAllText($Path)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    return ($text | ConvertFrom-Json)
}

# Racine de RAGO-COMM (« R:\ » ou « C:\Rago\comm\ »), ou $null si absente.
# M5 : Windows démarre à froid et s'arrête complètement (démarrage rapide coupé),
# donc son cache FAT n'est jamais périmé. M6 (hibernation de Windows) devra
# DÉMONTER RAGO-COMM avant d'hiberner : Linux y écrit pendant que Windows dort.
function Get-RagoCommRoot {
    $vols = @(Get-CimInstance -ClassName Win32_Volume -Filter ("Label = '{0}'" -f $script:CommLabel))
    if ($vols.Count -eq 0) {
        Write-RagoLog ('partition {0} introuvable' -f $script:CommLabel) 'WARN'
        return $null
    }
    if ($vols.Count -gt 1) {
        Write-RagoLog ('{0} volumes nommés {1} : le premier en FAT32 est pris' -f $vols.Count, $script:CommLabel) 'WARN'
    }
    $vol = $vols | Where-Object { $_.FileSystem -eq 'FAT32' } | Select-Object -First 1
    if ($null -eq $vol) {
        Write-RagoLog ('{0} trouvée mais pas en FAT32 ({1}) : ignorée' -f $script:CommLabel, $vols[0].FileSystem) 'ERROR'
        return $null
    }
    if ($vol.DriveLetter) { return ($vol.DriveLetter + '\') }
    # Pas de lettre : point de montage dans un dossier NTFS vide (un dossier
    # déjà monté est un point d'analyse, « reparse point »).
    $at = $script:CommMountAt + '\'
    if (-not (Test-Path -LiteralPath $script:CommMountAt)) {
        New-Item -ItemType Directory -Path $script:CommMountAt -Force | Out-Null
    }
    $item = Get-Item -LiteralPath $script:CommMountAt -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
        $r = Invoke-CimMethod -InputObject $vol -MethodName AddMountPoint -Arguments @{ Directory = $at }
        if ($r.ReturnValue -ne 0) {
            Write-RagoLog ('montage de {0} sur {1} impossible (code {2})' -f $script:CommLabel, $at, $r.ReturnValue) 'ERROR'
            return $null
        }
    }
    return $at
}

# CompactOS en place ? Taille sur le disque (GetCompressedFileSizeW, qui compte la
# compression WOF de CompactOS) de fichiers système contre leur taille réelle.
# $true / $false, ou $null si la mesure est impossible.
function Test-RagoCompactOS {
    if (-not ('Rago.NativeFile' -as [type])) {
        Add-Type -Namespace Rago -Name NativeFile -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
public static extern uint GetCompressedFileSizeW(string lpFileName, out uint lpFileSizeHigh);
'@
    }
    $files = @('ntdll.dll', 'kernel32.dll', 'shell32.dll', 'mshtml.dll') | ForEach-Object { Join-Path $env:SystemRoot ('System32\' + $_) } |
        Where-Object { Test-Path -LiteralPath $_ }
    if (@($files).Count -eq 0) { return $null }
    $real = 0.0; $onDisk = 0.0
    foreach ($f in $files) {
        $high = [uint32]0
        $low = [Rago.NativeFile]::GetCompressedFileSizeW($f, [ref]$high)
        if ($low -eq [uint32]::MaxValue -and [System.Runtime.InteropServices.Marshal]::GetLastWin32Error() -ne 0) { return $null }
        $onDisk += [double]$high * 4294967296.0 + [double]$low
        $real += [double](Get-Item -LiteralPath $f -Force).Length
    }
    if ($real -le 0) { return $null }
    return (($onDisk / $real) -lt 0.85)
}

# Valeur de RAGO_WINDOWS_SECURITY acceptée.
function Test-RagoSecurityValue {
    param([string]$Value)
    return ($Value -eq 'compat_max' -or $Value -eq 'perf')
}

Export-ModuleMember -Function Get-RagoDataDir, Get-RagoRootDir, Set-RagoLogName, Write-RagoLog, Get-RagoUtcNow,
    Get-RagoBootId, ConvertTo-RagoJson, Write-RagoJson, Read-RagoJson, Get-RagoCommRoot, Test-RagoCompactOS, Test-RagoSecurityValue
