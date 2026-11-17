<#
.SYNOPSIS
Installs zp on Windows from an archive that carries its own Node.js.

.DESCRIPTION
The machine needs no Node.js and no npm. The script needs no admin rights.
It writes only below %LOCALAPPDATA%\Zuper:
  %LOCALAPPDATA%\Zuper\zp\<version>\   zp and its Node.js
  %LOCALAPPDATA%\Zuper\bin\zp.cmd      the file that starts zp

The one command, from the public repo of the releases. It downloads the newest release, checks it and installs it:

  powershell -ExecutionPolicy Bypass -c "irm https://raw.githubusercontent.com/ZuperHQ/zp-releases/main/install.ps1 | iex"

For one release, pass -Version:

  powershell -ExecutionPolicy Bypass -c "& ([scriptblock]::Create((irm https://raw.githubusercontent.com/ZuperHQ/zp-releases/main/install.ps1))) -Version X.Y.Z"

Windows blocks script files by default, so start a copy of this script like this:

  powershell -ExecutionPolicy Bypass -File install.ps1 [-Version X.Y.Z]
      downloads the newest release, or the release X.Y.Z
  powershell -ExecutionPolicy Bypass -File install.ps1 <archive>
      <archive> is a path, or an http(s) URL
  powershell -ExecutionPolicy Bypass -File install.ps1 <archive> -Sums <SHA256SUMS>
      checks the archive first. <SHA256SUMS> is a path or a URL.
  powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall
      removes zp

A download from the releases is always checked against the SHA256SUMS of the same release.
A file named SHA256SUMS beside a local archive is used without -Sums.
To update, run the script again. scripts/pack.mjs makes the archives.

.github/workflows/install.yml runs the install from a local archive on windows-latest, and it has passed.
THE DOWNLOAD FROM THE RELEASES AND -Version WERE NOT RUN ON WINDOWS YET (17 Nov 2026). No release exists yet.
#>
[CmdletBinding()]
param(
	[Parameter(Position = 0)][string]$Archive = '',
	[string]$Sums = '',
	[string]$Version = '',
	[switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
# The progress bar of Windows PowerShell 5.1 makes downloads and Expand-Archive many times slower.
$ProgressPreference = 'SilentlyContinue'

if (-not $env:LOCALAPPDATA) {
	Write-Host 'install.ps1: LOCALAPPDATA is not set. Run this script on Windows.' -ForegroundColor Red
	exit 1
}

# The public repo that holds the releases. ZP_RELEASES_URL names another server with the same two paths:
# <url>/latest/download/<file> and <url>/download/vX.Y.Z/<file>.
$ReleasesUrl = 'https://github.com/ZuperHQ/zp-releases/releases'
if ($env:ZP_RELEASES_URL) { $ReleasesUrl = $env:ZP_RELEASES_URL }

$Target = 'win32-x64'
$ArchiveName = "zp-$Target.zip"
$SumsName = 'SHA256SUMS'
$ZuperRoot = Join-Path $env:LOCALAPPDATA 'Zuper'
$InstallRoot = Join-Path $ZuperRoot 'zp'
$BinDir = Join-Path $ZuperRoot 'bin'
$Shim = Join-Path $BinDir 'zp.cmd'

function Test-Url([string]$Value) {
	return $Value -match '^https?://'
}

# Returns the address of a file of a release: of the release $Wanted, or of the newest one when it is empty.
function Get-ReleaseUrl([string]$Wanted, [string]$File) {
	if ($Wanted) { return "$ReleasesUrl/download/v$Wanted/$File" }
	return "$ReleasesUrl/latest/download/$File"
}

function Get-Download([string]$Url, [string]$File) {
	# Windows PowerShell 5.1 may offer only old TLS versions, which GitHub and most hosts refuse.
	[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
	try {
		Invoke-WebRequest -Uri $Url -OutFile $File -UseBasicParsing
	} catch {
		throw "Could not download $Url. $($_.Exception.Message)"
	}
}

# Returns the hash that a sums file gives for a file name, in lower case, or '' when it has no line for the name.
function Get-ExpectedSum([string]$SumsFile, [string]$Name) {
	foreach ($line in Get-Content -LiteralPath $SumsFile) {
		if ($line -match '^([0-9a-fA-F]{64}) [ *](.+)$' -and $Matches[2] -eq $Name) {
			return $Matches[1].ToLowerInvariant()
		}
	}
	return ''
}

function Test-InUserPath([string]$Dir) {
	$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
	if (-not $userPath) { return $false }
	$entries = $userPath.Split(';') | ForEach-Object { $_.Trim().TrimEnd('\') }
	return $entries -contains $Dir.TrimEnd('\')
}

function Uninstall-Zp {
	if (-not (Test-Path -LiteralPath $InstallRoot) -and -not (Test-Path -LiteralPath $Shim)) {
		Write-Host "zp is not installed in $ZuperRoot. Nothing was removed."
		return
	}
	if (Test-Path -LiteralPath $InstallRoot) { Remove-Item -LiteralPath $InstallRoot -Recurse -Force }
	if (Test-Path -LiteralPath $Shim) { Remove-Item -LiteralPath $Shim -Force }
	foreach ($dir in @($BinDir, $ZuperRoot)) {
		if ((Test-Path -LiteralPath $dir) -and -not (Get-ChildItem -LiteralPath $dir -Force)) {
			Remove-Item -LiteralPath $dir -Force
		}
	}
	$zuperHome = Join-Path $env:USERPROFILE '.zuper'
	Write-Host "Removed $InstallRoot and $Shim."
	Write-Host "Your sign-in ($zuperHome\credentials.json) and the SDK copy ($zuperHome\sdk) stay."
	Write-Host "To remove them too: Remove-Item -Recurse -Force `"$zuperHome`""
	if (Test-InUserPath $BinDir) {
		Write-Host "$BinDir is still in your PATH. Remove it in Settings > System > About > Advanced system settings > Environment Variables."
	}
}

function Show-PathHelp {
	if (Test-InUserPath $BinDir) {
		Write-Host 'zp is in your PATH. Open a new terminal, and run: zp --help'
		return
	}
	Write-Host ''
	Write-Host 'To run zp by its name, run this line once, then open a new terminal:'
	Write-Host ''
	Write-Host "  [Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path', 'User') + ';$BinDir', 'User')"
	Write-Host ''
	Write-Host "Until then, run it as: $Shim"
}

function Install-Zp {
	# The archive holds the x64 Node.js. Windows on ARM runs it through its x64 emulation.
	$arch = $env:PROCESSOR_ARCHITEW6432
	if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
	if ($arch -ne 'AMD64' -and $arch -ne 'ARM64') {
		throw "zp has no archive for the processor $arch. It needs 64-bit Windows."
	}

	$archivePath = $Archive
	$sumsPath = $Sums
	if (-not $archivePath) {
		# With no archive given, download it from the releases, with the SHA256SUMS beside it.
		# 1.2.3 and v1.2.3 name the same release.
		$wanted = $Version -replace '^v', ''
		if ($wanted -and $wanted -notmatch '^[0-9A-Za-z][0-9A-Za-z.-]*$') {
			throw "-Version needs a version, such as 1.2.3. Got: $Version"
		}
		$archivePath = Get-ReleaseUrl $wanted $ArchiveName
		if (-not $sumsPath) { $sumsPath = Get-ReleaseUrl $wanted $SumsName }
	} elseif ($Version) {
		throw '-Version picks a release to download. Do not pass it with an archive.'
	}

	New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
	$work = Join-Path $InstallRoot ('.install-' + [Guid]::NewGuid().ToString('N'))
	New-Item -ItemType Directory -Path $work | Out-Null
	try {
		if (Test-Url $archivePath) {
			# The name that SHA256SUMS lists: the file name, without the query of the URL.
			$listedName = Split-Path -Leaf ([Uri]$archivePath).AbsolutePath
			$archiveFile = Join-Path $work $listedName
			Write-Host "Downloading $archivePath"
			Get-Download $archivePath $archiveFile
		} else {
			if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) { throw "$archivePath is not a file." }
			# ProviderPath is the plain path. Path can carry a PowerShell prefix, for a network share or a PowerShell drive.
			$archiveFile = (Resolve-Path -LiteralPath $archivePath).ProviderPath
			$listedName = Split-Path -Leaf $archiveFile
			$beside = Join-Path (Split-Path -Parent $archiveFile) $SumsName
			if (-not $sumsPath -and (Test-Path -LiteralPath $beside -PathType Leaf)) { $sumsPath = $beside }
		}

		if ($sumsPath) {
			if (Test-Url $sumsPath) {
				$sumsFile = Join-Path $work $SumsName
				Get-Download $sumsPath $sumsFile
			} else {
				if (-not (Test-Path -LiteralPath $sumsPath -PathType Leaf)) { throw "$sumsPath is not a file." }
				$sumsFile = $sumsPath
			}
			$expected = Get-ExpectedSum $sumsFile $listedName
			if (-not $expected) {
				throw "$sumsPath has no line for $listedName. Keep the archive's name as it was. Nothing was installed."
			}
			$actual = (Get-FileHash -LiteralPath $archiveFile -Algorithm SHA256).Hash.ToLowerInvariant()
			if ($actual -ne $expected) {
				throw "The sha256 of $listedName is $actual. $sumsPath says $expected. The file is broken or changed. Nothing was installed."
			}
			Write-Host "sha256 ok: $listedName matches $sumsPath"
		} else {
			Write-Host "No $SumsName was given, so the archive was not checked."
		}

		Expand-Archive -LiteralPath $archiveFile -DestinationPath $work -Force
		$unpacked = Join-Path $work 'zp'
		foreach ($needed in @('VERSION', 'TARGET', 'bin\node.exe', 'bin\zp.cmd', 'bin\run.js')) {
			if (-not (Test-Path -LiteralPath (Join-Path $unpacked $needed) -PathType Leaf)) {
				throw "$listedName is not a zp archive for Windows: it has no zp\$needed."
			}
		}
		$zpVersion = (Get-Content -LiteralPath (Join-Path $unpacked 'VERSION') -TotalCount 1).Trim()
		if ($zpVersion -notmatch '^[0-9A-Za-z][0-9A-Za-z.-]*$') {
			throw "$listedName has a version that is not valid: $zpVersion"
		}
		$archiveTarget = (Get-Content -LiteralPath (Join-Path $unpacked 'TARGET') -TotalCount 1).Trim()
		if ($archiveTarget -ne $Target) {
			throw "This archive is for $archiveTarget. This machine needs $ArchiveName."
		}

		$dest = Join-Path $InstallRoot $zpVersion
		if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
		Move-Item -LiteralPath $unpacked -Destination $dest
	} finally {
		# A file that a virus scanner still holds must not stop an install that is done, or hide the real error.
		if (Test-Path -LiteralPath $work) {
			Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
		}
	}

	# Windows needs special rights for links. So zp.cmd in bin\ is a small file that starts the installed version.
	# The path is relative to the file itself, so a user name with other letters cannot break it.
	New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
	Set-Content -LiteralPath $Shim -Encoding ASCII -Value @('@echo off', "`"%~dp0..\zp\$zpVersion\bin\zp.cmd`" %*")

	$printed = & $Shim --version
	if ($LASTEXITCODE -ne 0) { throw "zp was unpacked to $dest, but it does not start." }

	# An update leaves one version in place.
	Get-ChildItem -LiteralPath $InstallRoot -Directory | Where-Object { $_.Name -ne $zpVersion } | ForEach-Object {
		# A folder named .install-... is what a stopped install left behind. It goes too, without a line.
		Remove-Item -LiteralPath $_.FullName -Recurse -Force
		if ($_.Name -notlike '.install-*') { Write-Host "Removed the older version $($_.Name)." }
	}

	Write-Host "Installed zp $zpVersion in $dest"
	Write-Host "  $printed"
	Show-PathHelp
}

try {
	if ($Uninstall) { Uninstall-Zp } else { Install-Zp }
} catch {
	Write-Host "install.ps1: $($_.Exception.Message)" -ForegroundColor Red
	exit 1
}
