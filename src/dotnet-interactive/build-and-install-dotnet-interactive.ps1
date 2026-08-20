<#
.SYNOPSIS
Builds the local dotnet-interactive tool and its matching VS Code VSIX.

.DESCRIPTION
The script generates the TypeScript contracts, builds and packs the
Microsoft.dotnet-interactive global tool, then packages a VSIX whose required
tool version and local acquisition source match the generated nupkg.

Git symlink placeholders used by the VS Code projects are repaired through the
repository's ensure-symlinks.ps1 before the frontend compile.

It is compatible with Windows PowerShell 5.1 and PowerShell 7. The source
package.json is restored byte-for-byte after VSIX packaging.

.PARAMETER ToolVersion
NuGet tool version. When omitted, the version evaluated by MSBuild is used.

.PARAMETER Configuration
Build configuration. Release is the supported default for distributable output.

.PARAMETER OutputDirectory
Directory receiving the tool nupkg. The VSIX is written to its stable subfolder.

.PARAMETER SkipInstall
Builds both artifacts without replacing the globally installed tool.

.PARAMETER ReuseToolPackage
Reuses an existing exact-version nupkg and resumes at VSIX packaging.

.EXAMPLE
.\build-and-install-dotnet-interactive.ps1

.EXAMPLE
.\build-and-install-dotnet-interactive.ps1 -ToolVersion 1.0.741801 -SkipInstall
#>
[CmdletBinding()]
param(
    [string]$ToolVersion = "",
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",
    [string]$OutputDirectory = "",
    [switch]$ReuseToolPackage,
    [switch]$SkipInstall
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Get-FullPath {
    param(
        [string]$BasePath,
        [string]$ChildPath
    )

    return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($BasePath, $ChildPath))
}

function Invoke-NativeCommand {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory
    )

    Push-Location -LiteralPath $WorkingDirectory
    try {
        Write-Host "[build-and-install] $FilePath $($Arguments -join ' ')"
        & $FilePath @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "Command failed with exit code ${LASTEXITCODE}: $FilePath"
        }
    } finally {
        Pop-Location
    }
}

function Set-JsonSettingDefault {
    param(
        [string]$Json,
        [string]$SettingName,
        [string]$EscapedJsonValue
    )

    $escapedSettingName = [System.Text.RegularExpressions.Regex]::Escape($SettingName)
    $pattern = '("' + $escapedSettingName + '"\s*:\s*\{.*?"default"\s*:\s*")[^"]*(")'
    $matches = [System.Text.RegularExpressions.Regex]::Matches(
        $Json,
        $pattern,
        [System.Text.RegularExpressions.RegexOptions]::Singleline)

    if ($matches.Count -ne 1) {
        throw "Expected exactly one default value for '$SettingName', but found $($matches.Count)."
    }

    $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{
        param($match)
        return $match.Groups[1].Value + $EscapedJsonValue + $match.Groups[2].Value
    }

    return [System.Text.RegularExpressions.Regex]::Replace(
        $Json,
        $pattern,
        $evaluator,
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
}

function Assert-ToolPackage {
    param(
        [string]$PackagePath
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)
    try {
        $fsharpAssembly = $archive.Entries |
            Where-Object { $_.FullName -like "tools/*/Microsoft.DotNet.Interactive.FSharp.dll" } |
            Select-Object -First 1

        if ($null -eq $fsharpAssembly) {
            throw "The tool package does not contain Microsoft.DotNet.Interactive.FSharp.dll."
        }
    } finally {
        $archive.Dispose()
    }
}

function Assert-VsixConfiguration {
    param(
        [string]$VsixPath,
        [string]$ExpectedToolVersion,
        [string]$ExpectedToolSource,
        [string]$ExpectedPublisher,
        [string]$ExpectedExtensionName
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($VsixPath)
    try {
        $packageJsonEntry = $archive.GetEntry("extension/package.json")
        if ($null -eq $packageJsonEntry) {
            throw "The VSIX does not contain extension/package.json."
        }

        $reader = New-Object System.IO.StreamReader($packageJsonEntry.Open())
        try {
            $packageJson = $reader.ReadToEnd() | ConvertFrom-Json
        } finally {
            $reader.Dispose()
        }

        $properties = $packageJson.contributes.configuration.properties
        $actualToolVersion = $properties."dotnet-interactive.requiredInteractiveToolVersion".default
        $actualToolSource = $properties."dotnet-interactive.interactiveToolSource".default

        if ($packageJson.publisher -ne $ExpectedPublisher -or $packageJson.name -ne $ExpectedExtensionName) {
            throw "VSIX identity mismatch. Expected '$ExpectedPublisher.$ExpectedExtensionName', found '$($packageJson.publisher).$($packageJson.name)'."
        }

        if ($actualToolVersion -ne $ExpectedToolVersion) {
            throw "VSIX tool version mismatch. Expected '$ExpectedToolVersion', found '$actualToolVersion'."
        }

        if ($actualToolSource -ne $ExpectedToolSource) {
            throw "VSIX tool source mismatch. Expected '$ExpectedToolSource', found '$actualToolSource'."
        }
    } finally {
        $archive.Dispose()
    }
}

$scriptDirectory = [System.IO.Path]::GetFullPath($PSScriptRoot)
$repoRoot = Get-FullPath -BasePath $scriptDirectory -ChildPath "..\.."
$toolProject = Get-FullPath -BasePath $scriptDirectory -ChildPath "dotnet-interactive.csproj"
$interfaceGeneratorProject = Get-FullPath -BasePath $scriptDirectory -ChildPath "..\interface-generator\interface-generator.csproj"
$contractsPath = Get-FullPath -BasePath $scriptDirectory -ChildPath "..\polyglot-notebooks\src\contracts.ts"
$vscodeDirectory = Get-FullPath -BasePath $scriptDirectory -ChildPath "..\polyglot-notebooks-vscode"
$packageJsonPath = Get-FullPath -BasePath $vscodeDirectory -ChildPath "package.json"
$packageJsonBackupPath = $packageJsonPath + ".build-and-install.backup"
$ensureSymlinksScript = Get-FullPath -BasePath $scriptDirectory -ChildPath "..\ensure-symlinks.ps1"

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Get-FullPath -BasePath $repoRoot -ChildPath "自主版"
} elseif (-not [System.IO.Path]::IsPathRooted($OutputDirectory)) {
    $OutputDirectory = Get-FullPath -BasePath (Get-Location).Path -ChildPath $OutputDirectory
} else {
    $OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
}

$stableOutputDirectory = Get-FullPath -BasePath $OutputDirectory -ChildPath "stable"
[System.IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
[System.IO.Directory]::CreateDirectory($stableOutputDirectory) | Out-Null

if ([string]::IsNullOrWhiteSpace($ToolVersion)) {
    $versionOutput = & dotnet msbuild $toolProject -nologo -getProperty:Version "-p:Configuration=$Configuration"
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to evaluate the dotnet-interactive version."
    }

    $ToolVersion = $versionOutput |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -match '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$' } |
        Select-Object -Last 1
}

if ([string]::IsNullOrWhiteSpace($ToolVersion) -or
    $ToolVersion -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') {
    throw "ToolVersion must be a valid NuGet semantic version. Actual value: '$ToolVersion'."
}

$vsixVersion = ($ToolVersion -split '\+', 2)[0]
$toolPackagePath = Get-FullPath -BasePath $OutputDirectory -ChildPath "Microsoft.dotnet-interactive.$ToolVersion.nupkg"
$vsixPath = Get-FullPath -BasePath $stableOutputDirectory -ChildPath "coldfar-interactive-notebooks-$vsixVersion.vsix"

if (Test-Path -LiteralPath $packageJsonBackupPath) {
    throw "A previous package.json backup still exists: $packageJsonBackupPath. Restore or remove it before running this script."
}

Write-Host "[build-and-install] Repository: $repoRoot"
Write-Host "[build-and-install] Configuration: $Configuration"
Write-Host "[build-and-install] Tool version: $ToolVersion"
Write-Host "[build-and-install] Output: $OutputDirectory"

if (-not $ReuseToolPackage) {
    Invoke-NativeCommand -FilePath "dotnet" -WorkingDirectory $repoRoot -Arguments @(
        "run",
        "--project", $interfaceGeneratorProject,
        "--configuration", $Configuration,
        "--",
        "--out-file", $contractsPath)

    Invoke-NativeCommand -FilePath "dotnet" -WorkingDirectory $repoRoot -Arguments @(
        "pack", $toolProject,
        "--configuration", $Configuration,
        "-p:Version=$ToolVersion",
        "-p:PackageVersion=$ToolVersion",
        "--output", $OutputDirectory)
} else {
    Write-Host "[build-and-install] Reusing tool package: $toolPackagePath"
}

if (-not (Test-Path -LiteralPath $toolPackagePath -PathType Leaf)) {
    throw "Expected tool package was not created: $toolPackagePath"
}

Assert-ToolPackage -PackagePath $toolPackagePath

$requiredSourceLinks = @(
    (Get-FullPath -BasePath $scriptDirectory -ChildPath "..\polyglot-notebooks-vscode-common\src\polyglot-notebooks"),
    (Get-FullPath -BasePath $scriptDirectory -ChildPath "..\polyglot-notebooks-vscode\src\ui"),
    (Get-FullPath -BasePath $scriptDirectory -ChildPath "..\polyglot-notebooks-vscode\src\vscode-common")
)

$sourceLinksNeedRepair = $false
foreach ($sourceLinkPath in $requiredSourceLinks) {
    $sourceLink = Get-Item -LiteralPath $sourceLinkPath -Force -ErrorAction SilentlyContinue
    if ($null -eq $sourceLink -or -not ($sourceLink.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        $sourceLinksNeedRepair = $true
        break
    }
}

if ($sourceLinksNeedRepair) {
    Write-Host "[build-and-install] Repairing repository source symlinks."
    & $ensureSymlinksScript
}

foreach ($sourceLinkPath in $requiredSourceLinks) {
    $sourceLink = Get-Item -LiteralPath $sourceLinkPath -Force -ErrorAction SilentlyContinue
    if ($null -eq $sourceLink -or -not ($sourceLink.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        throw "Required source symlink is unavailable after repair: $sourceLinkPath"
    }
}

$nodeRequirements = @(
    @{
        Directory = $vscodeDirectory
        Command = "node_modules\.bin\vsce.cmd"
    },
    @{
        Directory = (Get-FullPath -BasePath $scriptDirectory -ChildPath "..\polyglot-notebooks")
        Command = "node_modules\.bin\rollup.cmd"
    },
    @{
        Directory = (Get-FullPath -BasePath $scriptDirectory -ChildPath "..\polyglot-notebooks-ui-components")
        Command = "node_modules\.bin\webpack.cmd"
    })

foreach ($requirement in $nodeRequirements) {
    $requiredCommand = Get-FullPath -BasePath $requirement.Directory -ChildPath $requirement.Command
    if (-not (Test-Path -LiteralPath $requiredCommand -PathType Leaf)) {
        Invoke-NativeCommand -FilePath "npm" -WorkingDirectory $requirement.Directory -Arguments @(
            "install",
            "--registry", "https://registry.npmjs.org",
            "--package-lock=false",
            "--no-audit",
            "--no-fund")
    }

    if (-not (Test-Path -LiteralPath $requiredCommand -PathType Leaf)) {
        throw "Required Node command was not restored: $requiredCommand"
    }
}

$vscePath = Get-FullPath -BasePath $vscodeDirectory -ChildPath "node_modules\.bin\vsce.cmd"
if (-not (Test-Path -LiteralPath $vscePath -PathType Leaf)) {
    throw "Local vsce command was not found after npm restore: $vscePath"
}

$originalPackageJson = [System.IO.File]::ReadAllBytes($packageJsonPath)
[System.IO.File]::WriteAllBytes($packageJsonBackupPath, $originalPackageJson)

try {
    $utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
    $packageJsonText = $utf8Strict.GetString($originalPackageJson)
    $escapedToolSource = $OutputDirectory.Replace("\", "\\").Replace('"', '\"')
    $packageJsonText = Set-JsonSettingDefault `
        -Json $packageJsonText `
        -SettingName "dotnet-interactive.interactiveToolSource" `
        -EscapedJsonValue $escapedToolSource
    $packageJsonText = Set-JsonSettingDefault `
        -Json $packageJsonText `
        -SettingName "dotnet-interactive.requiredInteractiveToolVersion" `
        -EscapedJsonValue $ToolVersion

    [System.IO.File]::WriteAllText($packageJsonPath, $packageJsonText, $utf8Strict)
    Get-Content -LiteralPath $packageJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json | Out-Null

    Invoke-NativeCommand -FilePath $vscePath -WorkingDirectory $vscodeDirectory -Arguments @(
        "package", $vsixVersion,
        "--no-update-package-json",
        "--out", $vsixPath)
} finally {
    if (Test-Path -LiteralPath $packageJsonBackupPath -PathType Leaf) {
        $backupBytes = [System.IO.File]::ReadAllBytes($packageJsonBackupPath)
        [System.IO.File]::WriteAllBytes($packageJsonPath, $backupBytes)
        Remove-Item -LiteralPath $packageJsonBackupPath -Force
    }
}

if (-not (Test-Path -LiteralPath $vsixPath -PathType Leaf)) {
    throw "Expected VSIX was not created: $vsixPath"
}

Assert-VsixConfiguration `
    -VsixPath $vsixPath `
    -ExpectedToolVersion $ToolVersion `
    -ExpectedToolSource $OutputDirectory `
    -ExpectedPublisher "ingted" `
    -ExpectedExtensionName "coldfar-interactive-notebooks"

if (-not $SkipInstall) {
    $installedTools = & dotnet tool list --global
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list globally installed .NET tools."
    }

    $isInstalled = $null -ne ($installedTools |
        Where-Object { $_ -match '^\s*Microsoft\.dotnet-interactive\s+' } |
        Select-Object -First 1)

    if ($isInstalled) {
        Invoke-NativeCommand -FilePath "dotnet" -WorkingDirectory $repoRoot -Arguments @(
            "tool", "update", "--global", "Microsoft.dotnet-interactive",
            "--source", $OutputDirectory,
            "--version", $ToolVersion,
            "--allow-downgrade")
    } else {
        Invoke-NativeCommand -FilePath "dotnet" -WorkingDirectory $repoRoot -Arguments @(
            "tool", "install", "--global", "Microsoft.dotnet-interactive",
            "--source", $OutputDirectory,
            "--version", $ToolVersion)
    }
}

Write-Host "[build-and-install] Tool package: $toolPackagePath" -ForegroundColor Green
Write-Host "[build-and-install] VSIX: $vsixPath" -ForegroundColor Green
if ($SkipInstall) {
    Write-Host "[build-and-install] Global tool installation was skipped."
} else {
    Write-Host "[build-and-install] Global tool version $ToolVersion is installed." -ForegroundColor Green
}
