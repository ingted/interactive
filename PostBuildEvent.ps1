[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $PackageId,

    [Parameter(Mandatory = $true)]
    [string] $PackageVersion,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration,

    [Parameter(Mandatory = $true)]
    [string] $ProjectDirectory,

    [string] $PackageFilePath,

    [string] $PackageOutputPath,

    [switch] $PushRelease
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$nuGetSourceUrl = 'https://api.nuget.org/v3/index.json'

function Get-NuGetApiKey {
    $keyPaths = @(
        '/Nuget/apikey.txt',
        'G:\Nuget\apikey.txt',
        'C:\Nuget\apikey.txt'
    )

    foreach ($keyPath in $keyPaths) {
        if (Test-Path -LiteralPath $keyPath -PathType Leaf) {
            $apiKey = [IO.File]::ReadAllText($keyPath).Trim()
            if (-not [string]::IsNullOrWhiteSpace($apiKey)) {
                return $apiKey
            }
        }
    }

    throw 'NuGet API key file was not found or was empty.'
}

function Publish-NuGetPackage {
    param(
        [Parameter(Mandatory = $true)]
        [IO.FileInfo] $Package
    )

    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        $pwsh = Get-Command pwsh.exe -ErrorAction Stop
        Write-Host "NUGET_PUSH_BRIDGE_BEGIN client=pwsh package=$($Package.Name) packagePath=$($Package.FullName) source=$nuGetSourceUrl"
        $arguments = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $PSCommandPath,
            '-PackageId', $PackageId,
            '-PackageVersion', $PackageVersion,
            '-Configuration', $Configuration,
            '-ProjectDirectory', $ProjectDirectory,
            '-PackageFilePath', $Package.FullName,
            '-PushRelease')
        & $pwsh.Source @arguments
        if ($LASTEXITCODE -ne 0) {
            throw "NuGet push through pwsh failed. exitCode=$LASTEXITCODE package=$($Package.Name)"
        }

        Write-Host "NUGET_PUSH_BRIDGE_OK client=pwsh package=$($Package.Name) packagePath=$($Package.FullName) source=$nuGetSourceUrl"
        return
    }

    Write-Host "NUGET_PUSH_BEGIN client=NuGet.Protocol package=$($Package.Name) packagePath=$($Package.FullName) source=$nuGetSourceUrl"
    $dotnetRoot = Split-Path (Get-Command dotnet -ErrorAction Stop).Source -Parent
    $sdkVersion = (& dotnet --version).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sdkVersion)) {
        throw 'Unable to resolve the active .NET SDK version for NuGet push.'
    }

    $sdkDirectory = Join-Path $dotnetRoot (Join-Path 'sdk' $sdkVersion)
    if (-not (Test-Path -LiteralPath $sdkDirectory -PathType Container)) {
        throw "Active .NET SDK directory does not exist. version=$sdkVersion"
    }

    $nuGetAssemblies = @{}
    Get-ChildItem -LiteralPath $sdkDirectory -Filter 'NuGet*.dll' -File |
        ForEach-Object {
            $assembly = [Reflection.Assembly]::LoadFrom($_.FullName)
            $nuGetAssemblies[$assembly.GetName().Name] = $assembly
        }

    $apiKey = Get-NuGetApiKey
    $repositoryType = $nuGetAssemblies['NuGet.Protocol'].GetType('NuGet.Protocol.Core.Types.Repository', $true)
    $packageSourceType = $nuGetAssemblies['NuGet.Configuration'].GetType('NuGet.Configuration.PackageSource', $true)
    $sourceRepositoryType = $nuGetAssemblies['NuGet.Protocol'].GetType('NuGet.Protocol.Core.Types.SourceRepository', $true)
    $packageUpdateType = $nuGetAssemblies['NuGet.Protocol'].GetType('NuGet.Protocol.Core.Types.PackageUpdateResource', $true)
    $logLevelType = $nuGetAssemblies['NuGet.Common'].GetType('NuGet.Common.LogLevel', $true)
    $commandOutputLoggerType = $nuGetAssemblies['NuGet.CommandLine.XPlat'].GetType('NuGet.CommandLine.XPlat.CommandOutputLogger', $true)
    $logger = [Activator]::CreateInstance(
        $commandOutputLoggerType,
        [object[]] @([Enum]::Parse($logLevelType, 'Information')))
    $pushStage = 'create-provider'
    try {
        $providerFactory = $repositoryType.GetProperty('Provider').GetValue($null, $null)
        $getCoreV3Method =
            $providerFactory.GetType().GetMethods() |
                Where-Object {
                    $_.Name -eq 'GetCoreV3' -and
                    $_.GetParameters().Count -eq 0
                } |
                Select-Object -First 1
        if ($null -eq $getCoreV3Method) {
            throw 'NuGet client GetCoreV3 method was not found.'
        }
        $providers = $getCoreV3Method.Invoke($providerFactory, @())
        $pushStage = 'create-repository'
        $source = [Activator]::CreateInstance(
            $packageSourceType,
            [object[]] @($nuGetSourceUrl))
        $repository = [Activator]::CreateInstance(
            $sourceRepositoryType,
            [object[]] @($source, $providers))
        $pushStage = 'resolve-resource-method'
        $resourceMethod =
            $sourceRepositoryType.GetMethods() |
                Where-Object {
                    $_.Name -eq 'GetResourceAsync' -and
                    $_.IsGenericMethodDefinition -and
                    $_.GetParameters().Count -eq 0
                } |
                Select-Object -First 1
        if ($null -eq $resourceMethod) {
            throw 'NuGet client GetResourceAsync method was not found.'
        }

        $closedResourceMethod =
            $resourceMethod.MakeGenericMethod(
                [Type[]] @($packageUpdateType))
        $pushStage = 'resolve-resource'
        $resourceTask = $closedResourceMethod.Invoke($repository, @())
        $resource = $resourceTask.GetAwaiter().GetResult()
        $pushStage = 'prepare-push'
        $packages = [Collections.Generic.List[string]]::new()
        $packages.Add($Package.FullName)
        $getApiKey = [Func[string, string]] { param($ignoredSource) $apiKey }
        $getSymbolApiKey = [Func[string, string]] { param($ignoredSource) $apiKey }
        $pushMethod =
            $packageUpdateType.GetMethods() |
                Where-Object {
                    $_.Name -eq 'PushAsync' -and
                    $_.GetParameters().Count -eq 11
                } |
                Select-Object -First 1
        if ($null -eq $pushMethod) {
            throw 'NuGet client PushAsync method was not found.'
        }

        $pushArguments = [object[]] @(
            $packages,
            $null,
            300,
            $false,
            $getApiKey,
            $getSymbolApiKey,
            $false,
            $true,
            $false,
            $false,
            $logger)
        $pushStage = 'invoke-push'
        Write-Host "Pushing: $($Package.Name) to nuget.org..."
        $pushTask = $pushMethod.Invoke($resource, $pushArguments)
        $null = $pushTask.GetAwaiter().GetResult()
    }
    catch {
        throw "NuGet push failed. client=NuGet.Protocol stage=$pushStage exceptionType=$($_.Exception.GetType().FullName) package=$($Package.Name)"
    }
    finally {
        $apiKey = $null
    }

    Write-Host "NUGET_PUSH_OK client=NuGet.Protocol package=$($Package.Name) packagePath=$($Package.FullName) source=$nuGetSourceUrl"
}

$resolvedProjectDirectory = [IO.Path]::GetFullPath($ProjectDirectory)
if (-not (Test-Path -LiteralPath $resolvedProjectDirectory -PathType Container)) {
    throw "Project directory does not exist. path=$resolvedProjectDirectory"
}

$packageFileName = "$PackageId.$PackageVersion.nupkg"
$packagePath =
    if (-not [string]::IsNullOrWhiteSpace($PackageFilePath)) {
        if ([IO.Path]::IsPathRooted($PackageFilePath)) {
            [IO.Path]::GetFullPath($PackageFilePath)
        }
        else {
            [IO.Path]::GetFullPath((Join-Path $resolvedProjectDirectory $PackageFilePath))
        }
    }
    else {
        $resolvedOutputDirectory =
            if ([string]::IsNullOrWhiteSpace($PackageOutputPath)) {
                Join-Path $resolvedProjectDirectory (Join-Path 'bin' $Configuration)
            }
            elseif ([IO.Path]::IsPathRooted($PackageOutputPath)) {
                [IO.Path]::GetFullPath($PackageOutputPath)
            }
            else {
                [IO.Path]::GetFullPath((Join-Path $resolvedProjectDirectory $PackageOutputPath))
            }

        Join-Path $resolvedOutputDirectory $packageFileName
    }

if ([IO.Path]::GetFileName($packagePath) -cne $packageFileName) {
    throw "Packed NuGet filename does not match package identity. expected=$packageFileName actual=$([IO.Path]::GetFileName($packagePath))"
}

if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
    throw "Packed NuGet file does not exist. path=$packagePath"
}

$libPacksFile = Join-Path $PSScriptRoot 'lib-packs.txt'
if (-not (Test-Path -LiteralPath $libPacksFile -PathType Leaf)) {
    throw "lib-packs.txt does not exist. path=$libPacksFile"
}

$libPacksDirectory = [IO.File]::ReadAllText($libPacksFile).Trim()
if ([string]::IsNullOrWhiteSpace($libPacksDirectory)) {
    throw 'lib-packs.txt is empty.'
}
if (-not [IO.Path]::IsPathRooted($libPacksDirectory)) {
    throw "lib-packs.txt must contain an absolute path. path=$libPacksDirectory"
}

$resolvedLibPacksDirectory = [IO.Path]::GetFullPath($libPacksDirectory)
if (-not (Test-Path -LiteralPath $resolvedLibPacksDirectory -PathType Container)) {
    throw "library-packs directory does not exist. path=$resolvedLibPacksDirectory"
}

$package = Get-Item -LiteralPath $packagePath
$destinationPath = Join-Path $resolvedLibPacksDirectory $package.Name
Write-Host "POST_BUILD_EVENT_BEGIN package=$($package.Name) packageId=$PackageId packageVersion=$PackageVersion configuration=$Configuration pushRelease=$($PushRelease.IsPresent)"
Write-Host "LIBRARY_PACK_COPY_BEGIN package=$($package.Name) source=$($package.FullName) destination=$destinationPath configuration=$Configuration"
Copy-Item -LiteralPath $package.FullName -Destination $destinationPath -Force
Write-Host "LIBRARY_PACK_COPY_OK package=$($package.Name) source=$($package.FullName) destination=$destinationPath bytes=$($package.Length) configuration=$Configuration"

if ($Configuration -eq 'Release' -and $PushRelease.IsPresent) {
    Publish-NuGetPackage -Package $package
}
else {
    $skipReason =
        if ($Configuration -ne 'Release') { 'configuration-not-release' }
        else { 'push-release-not-requested' }
    Write-Host "NUGET_PUSH_SKIPPED package=$($package.Name) packagePath=$($package.FullName) source=$nuGetSourceUrl configuration=$Configuration reason=$skipReason"
}

Write-Host "POST_BUILD_EVENT_OK package=$($package.Name) configuration=$Configuration destination=$destinationPath"
