[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$InstallerPath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$AppName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TargetVersion,

    [Parameter(Mandatory = $true)]
    [ValidateSet('MSI', 'EXE')]
    [string]$InstallerType,

    [string]$SilentArgs,

    [string]$LogDirectory = (Join-Path -Path $PSScriptRoot -ChildPath 'logs')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:LogPath = $null

function Write-DeploymentLog {
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')]
        [string]$Level,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [$Level] $Message"

    Write-Host $line
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
}

function ConvertTo-SafeVersion {
    param (
        [Parameter(Mandatory = $true)]
        [string]$VersionText
    )

    # Extract up to four numeric version components, such as 1.2.3.4.
    $match = [regex]::Match($VersionText, '\d+(\.\d+){0,3}')

    if (-not $match.Success) {
        return $null
    }

    try {
        return [version]$match.Value
    }
    catch {
        return $null
    }
}

function Get-InstalledApplication {
    param (
        [Parameter(Mandatory = $true)]
        [string]$DisplayName
    )

    $registryPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $matches = foreach ($path in $registryPaths) {
        Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
            Where-Object {
                $_.DisplayName -and $_.DisplayName -like "*$DisplayName*"
            } |
            Select-Object DisplayName, DisplayVersion, Publisher, InstallLocation, PSPath
    }

    if (-not $matches) {
        return $null
    }

    # Prefer the highest parseable version when more than one registry entry matches.
    return $matches |
        Sort-Object -Property @{ Expression = {
            $parsedVersion = ConvertTo-SafeVersion -VersionText ([string]$_.DisplayVersion)
            if ($null -eq $parsedVersion) { [version]'0.0' } else { $parsedVersion }
        }; Descending = $true } |
        Select-Object -First 1
}

function Test-VersionAtLeast {
    param (
        [Parameter(Mandatory = $true)]
        [string]$InstalledVersion,

        [Parameter(Mandatory = $true)]
        [string]$RequiredVersion
    )

    $installed = ConvertTo-SafeVersion -VersionText $InstalledVersion
    $required = ConvertTo-SafeVersion -VersionText $RequiredVersion

    if ($null -ne $installed -and $null -ne $required) {
        return $installed -ge $required
    }

    # Fall back to an exact string comparison for unusual vendor version formats.
    return $InstalledVersion.Trim() -eq $RequiredVersion.Trim()
}

function Invoke-SilentInstaller {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ResolvedInstallerPath,

        [Parameter(Mandatory = $true)]
        [ValidateSet('MSI', 'EXE')]
        [string]$Type,

        [string]$Arguments
    )

    if ($Type -eq 'MSI') {
        $process = Start-Process -FilePath 'msiexec.exe' `
            -ArgumentList "/i `"$ResolvedInstallerPath`" /qn /norestart" `
            -Wait `
            -PassThru
    }
    else {
        if ([string]::IsNullOrWhiteSpace($Arguments)) {
            throw 'SilentArgs is required for EXE installers because silent switches vary by vendor.'
        }

        $process = Start-Process -FilePath $ResolvedInstallerPath `
            -ArgumentList $Arguments `
            -Wait `
            -PassThru
    }

    return $process.ExitCode
}

try {
    if (-not (Test-Path -LiteralPath $LogDirectory -PathType Container)) {
        New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
    }

    $safeAppName = $AppName -replace '[^a-zA-Z0-9_-]', '_'
    $logFileName = '{0}_{1}.log' -f $safeAppName, (Get-Date -Format 'yyyyMMdd_HHmmss')
    $script:LogPath = Join-Path -Path $LogDirectory -ChildPath $logFileName

    $resolvedInstaller = (Resolve-Path -LiteralPath $InstallerPath).Path

    Write-DeploymentLog -Level INFO -Message "Starting deployment check for '$AppName'."
    Write-DeploymentLog -Level INFO -Message "Required version: $TargetVersion"
    Write-DeploymentLog -Level INFO -Message "Installer: $resolvedInstaller"

    $currentApp = Get-InstalledApplication -DisplayName $AppName

    if ($null -ne $currentApp) {
        $detectedVersion = [string]$currentApp.DisplayVersion
        Write-DeploymentLog -Level INFO -Message "Detected '$($currentApp.DisplayName)' version '$detectedVersion'."

        if (-not [string]::IsNullOrWhiteSpace($detectedVersion) -and
            (Test-VersionAtLeast -InstalledVersion $detectedVersion -RequiredVersion $TargetVersion)) {
            Write-DeploymentLog -Level SUCCESS -Message 'Required version is already installed. No deployment was necessary.'
            exit 0
        }

        Write-DeploymentLog -Level INFO -Message 'Installed version is missing or below the required version. Beginning deployment.'
    }
    else {
        Write-DeploymentLog -Level INFO -Message 'Application was not detected. Beginning deployment.'
    }

    $exitCode = Invoke-SilentInstaller `
        -ResolvedInstallerPath $resolvedInstaller `
        -Type $InstallerType `
        -Arguments $SilentArgs

    Write-DeploymentLog -Level INFO -Message "Installer completed with exit code $exitCode."

    $successfulExitCodes = @(0, 1641, 3010)
    if ($exitCode -notin $successfulExitCodes) {
        throw "Installer returned unsuccessful exit code $exitCode."
    }

    if ($exitCode -in @(1641, 3010)) {
        Write-DeploymentLog -Level WARN -Message 'Installation succeeded, but Windows reports that a restart is required.'
    }

    Start-Sleep -Seconds 2
    $verifiedApp = Get-InstalledApplication -DisplayName $AppName

    if ($null -eq $verifiedApp) {
        throw 'Verification failed: the application is still not present in the uninstall registry.'
    }

    $verifiedVersion = [string]$verifiedApp.DisplayVersion
    Write-DeploymentLog -Level INFO -Message "Post-install detection found '$($verifiedApp.DisplayName)' version '$verifiedVersion'."

    if ([string]::IsNullOrWhiteSpace($verifiedVersion)) {
        throw 'Verification failed: the application was detected, but no installed version was reported.'
    }

    if (-not (Test-VersionAtLeast -InstalledVersion $verifiedVersion -RequiredVersion $TargetVersion)) {
        throw "Verification failed: installed version '$verifiedVersion' does not meet required version '$TargetVersion'."
    }

    Write-DeploymentLog -Level SUCCESS -Message "Deployment and verification completed successfully for '$AppName'."
    exit 0
}
catch {
    if ($script:LogPath) {
        Write-DeploymentLog -Level ERROR -Message $_.Exception.Message
    }
    else {
        Write-Error $_.Exception.Message
    }

    exit 1
}
