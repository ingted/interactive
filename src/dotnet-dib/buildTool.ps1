<#
.SYNOPSIS
Builds, packs, and globally installs the local dotnet-dib .NET tool.

.DESCRIPTION
The script builds dotnet-dib and its project references, creates the
dotnet-dib NuGet tool package, and installs that exact local package as a
global .NET tool. The installed package hash is compared with the package
produced by this run.

When the same version is already installed, it is uninstalled and installed
again so rebuilding without changing the version still deploys the new bits.

Compatible with Windows PowerShell 5.1 and PowerShell 7.

.PARAMETER Configuration
Build configuration. Release is the default.

.PARAMETER ToolVersion
Package version. When omitted, the version evaluated by MSBuild is used.

.PARAMETER OutputDirectory
Directory receiving the dotnet-dib nupkg. Relative paths are resolved from
the repository root.

.EXAMPLE
.\buildTool.ps1

.EXAMPLE
.\buildTool.ps1 -ToolVersion 1.0.741801
#>
[CmdletBinding()]
param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",
    [string]$ToolVersion = "",
    [string]$OutputDirectory = ""
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Get-FullPath {
    param(
        [string]$BasePath,
        [string]$ChildPath
    )

    return [System.IO.Path]::GetFullPath(
        [System.IO.Path]::Combine($BasePath, $ChildPath))
}

function Invoke-DotNet {
    param(
        [string[]]$Arguments,
        [string]$WorkingDirectory
    )

    Push-Location -LiteralPath $WorkingDirectory
    try {
        Write-Host "[dotnet-dib] dotnet $($Arguments -join ' ')"
        & dotnet @Arguments

        if ($LASTEXITCODE -ne 0) {
            throw "dotnet command failed with exit code $LASTEXITCODE."
        }
    } finally {
        Pop-Location
    }
}

function Get-GlobalTool {
    param([string]$PackageId)

    $jsonLines = & dotnet tool list --global --format json
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list global .NET tools."
    }

    $toolList = ($jsonLines -join [Environment]::NewLine) | ConvertFrom-Json
    return @($toolList.data) |
        Where-Object { $_.packageId -eq $PackageId } |
        Select-Object -First 1
}

function Get-Sha256 {
    param([string]$Path)

    $stream = [System.IO.File]::OpenRead($Path)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [System.BitConverter]::ToString(
            $sha256.ComputeHash($stream)).Replace("-", "")
    } finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
}

function Assert-ToolPackage {
    param(
        [string]$PackagePath,
        [string]$ExpectedVersion
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)

    try {
        $nuspecEntry = $archive.Entries |
            Where-Object { $_.FullName -like "*.nuspec" } |
            Select-Object -First 1

        if ($null -eq $nuspecEntry) {
            throw "The package does not contain a nuspec file: $PackagePath"
        }

        $reader = New-Object System.IO.StreamReader($nuspecEntry.Open())
        try {
            [xml]$nuspec = $reader.ReadToEnd()
        } finally {
            $reader.Dispose()
        }

        $packageId = [string]$nuspec.package.metadata.id
        $packageVersion = [string]$nuspec.package.metadata.version
        if ($packageId -ne "dotnet-dib" -or $packageVersion -ne $ExpectedVersion) {
            throw "Package identity mismatch. Found '$packageId $packageVersion'."
        }

        $settingsEntry = $archive.GetEntry(
            "tools/net10.0/any/DotnetToolSettings.xml")
        $assemblyEntry = $archive.GetEntry(
            "tools/net10.0/any/dotnet-dib.dll")

        if ($null -eq $settingsEntry -or $null -eq $assemblyEntry) {
            throw "The package is missing dotnet-dib .NET tool assets."
        }

        $settingsReader = New-Object System.IO.StreamReader($settingsEntry.Open())
        try {
            [xml]$settings = $settingsReader.ReadToEnd()
        } finally {
            $settingsReader.Dispose()
        }

        if ([string]$settings.DotNetCliTool.Commands.Command.Name -ne "dotnet-dib") {
            throw "DotnetToolSettings.xml does not expose the dotnet-dib command."
        }
    } finally {
        $archive.Dispose()
    }
}

$scriptDirectory = [System.IO.Path]::GetFullPath($PSScriptRoot)
$repoRoot = Get-FullPath -BasePath $scriptDirectory -ChildPath "..\.."
$projectPath = Get-FullPath -BasePath $scriptDirectory -ChildPath "dotnet-dib.csproj"

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Get-FullPath `
        -BasePath $repoRoot `
        -ChildPath "artifacts\packages\dotnet-dib"
} elseif ([System.IO.Path]::IsPathRooted($OutputDirectory)) {
    $OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
} else {
    $OutputDirectory = Get-FullPath `
        -BasePath $repoRoot `
        -ChildPath $OutputDirectory
}

[System.IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null

if ([string]::IsNullOrWhiteSpace($ToolVersion)) {
    $versionOutput = & dotnet msbuild $projectPath -nologo `
        -getProperty:Version "-p:Configuration=$Configuration"

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to evaluate the dotnet-dib version."
    }

    $ToolVersion = $versionOutput |
        ForEach-Object { $_.Trim() } |
        Where-Object {
            $_ -match '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$'
        } |
        Select-Object -Last 1
}

if ([string]::IsNullOrWhiteSpace($ToolVersion) -or
    $ToolVersion -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') {
    throw "ToolVersion must be a valid NuGet semantic version. Actual value: '$ToolVersion'."
}

$packagePath = Get-FullPath `
    -BasePath $OutputDirectory `
    -ChildPath "dotnet-dib.$ToolVersion.nupkg"

Write-Host "[dotnet-dib] Repository: $repoRoot"
Write-Host "[dotnet-dib] Configuration: $Configuration"
Write-Host "[dotnet-dib] Version: $ToolVersion"
Write-Host "[dotnet-dib] Package output: $OutputDirectory"

Invoke-DotNet `
    -WorkingDirectory $repoRoot `
    -Arguments @(
        "build",
        $projectPath,
        "--configuration", $Configuration,
        "--nologo",
        "-p:Version=$ToolVersion"
    )

Invoke-DotNet `
    -WorkingDirectory $repoRoot `
    -Arguments @(
        "pack",
        $projectPath,
        "--configuration", $Configuration,
        "--no-build",
        "--no-restore",
        "--output", $OutputDirectory,
        "--nologo",
        "-p:Version=$ToolVersion"
    )

if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
    throw "Expected package was not created: $packagePath"
}

Assert-ToolPackage -PackagePath $packagePath -ExpectedVersion $ToolVersion
$packageHash = Get-Sha256 -Path $packagePath
$installedTool = Get-GlobalTool -PackageId "dotnet-dib"

if ($null -eq $installedTool) {
    Invoke-DotNet `
        -WorkingDirectory $repoRoot `
        -Arguments @(
            "tool", "install",
            "--global",
            "dotnet-dib",
            "--version", $ToolVersion,
            "--source", $OutputDirectory,
            "--no-http-cache"
        )
} elseif ([string]$installedTool.version -eq $ToolVersion) {
    Write-Host "[dotnet-dib] Reinstalling the existing version $ToolVersion."
    Invoke-DotNet `
        -WorkingDirectory $repoRoot `
        -Arguments @("tool", "uninstall", "--global", "dotnet-dib")
    Invoke-DotNet `
        -WorkingDirectory $repoRoot `
        -Arguments @(
            "tool", "install",
            "--global",
            "dotnet-dib",
            "--version", $ToolVersion,
            "--source", $OutputDirectory,
            "--no-http-cache"
        )
} else {
    Invoke-DotNet `
        -WorkingDirectory $repoRoot `
        -Arguments @(
            "tool", "update",
            "--global",
            "dotnet-dib",
            "--version", $ToolVersion,
            "--source", $OutputDirectory,
            "--no-http-cache",
            "--allow-downgrade"
        )
}

$installedTool = Get-GlobalTool -PackageId "dotnet-dib"
if ($null -eq $installedTool -or [string]$installedTool.version -ne $ToolVersion) {
    throw "Global tool verification failed. Expected dotnet-dib $ToolVersion."
}

$userProfile = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::UserProfile)
$toolExecutable = Get-FullPath `
    -BasePath $userProfile `
    -ChildPath ".dotnet\tools\dotnet-dib.exe"
$installedPackage = Get-FullPath `
    -BasePath $userProfile `
    -ChildPath (
        ".dotnet\tools\.store\dotnet-dib\$ToolVersion\" +
        "dotnet-dib\$ToolVersion\dotnet-dib.$ToolVersion.nupkg")

if (-not (Test-Path -LiteralPath $toolExecutable -PathType Leaf)) {
    throw "Global tool executable was not created: $toolExecutable"
}

if (-not (Test-Path -LiteralPath $installedPackage -PathType Leaf)) {
    throw "Installed package was not found: $installedPackage"
}

$installedHash = Get-Sha256 -Path $installedPackage

if ($installedHash -ne $packageHash) {
    throw (
        "Installed package hash differs from the package built by this run. " +
        "Built: $packageHash; installed: $installedHash")
}

$reportedVersion = & $toolExecutable --version
if ($LASTEXITCODE -ne 0 -or
    -not ([string]$reportedVersion).StartsWith($ToolVersion)) {
    throw "dotnet-dib --version verification failed: '$reportedVersion'."
}

Write-Host "[dotnet-dib] Global tool deployed successfully."
Write-Host "[dotnet-dib] Executable: $toolExecutable"
Write-Host "[dotnet-dib] Version: $reportedVersion"
Write-Host "[dotnet-dib] Package SHA-256: $packageHash"
