# Interactive 自主版建置與部署紀錄（2026-10-22）

本文件記錄 2026-10-22 實際使用的腳本、命令、產物與驗證結果。所有 `G:\coldfar_py\interactive` package 僅供本機使用：Debug 與 Release 的 `Pack` 都會複製主 `.nupkg` 到 `lib-packs.txt` 指定目錄，任何 configuration 都不會由 project target 推送到 NuGet.org。

`Deedle.DotNet.Interactive.Extension` 位於另一個 repo，0.1.1 是本次唯一獲准推送到 NuGet.org 的 package。

## Source identity

- Interactive branch: `20260815_persistent_display_refresh`
- Interactive source commit: `8a5717a85215f4a325554868c86336410cbceae4`
- Shared PostBuild migration commit: `1f4605b185c8bf39abb592194017ebceab82c78e`
- Same-version global tool reinstall fix: `8a5717a85215f4a325554868c86336410cbceae4`
- Deedle branch: `main`
- Deedle source commit: `a201301bbad4e2689c2b0540745cd3cfb625fdb4`
- SDK: .NET SDK `10.0.402`
- Interactive local library package version: `1.0.0-dev.26522.2`
- Tool version: `1.0.752201`

## Shared PostBuild migration

Canonical inputs were copied byte-for-byte from `G:\PulseTrade.fs`:

```powershell
copy -LiteralPath 'G:\PulseTrade.fs\lib-packs.txt' -Destination 'G:\coldfar_py\interactive\lib-packs.txt' -Force
copy -LiteralPath 'G:\PulseTrade.fs\PostBuildEvent.ps1' -Destination 'G:\coldfar_py\interactive\PostBuildEvent.ps1' -Force
```

Verified source/destination hashes:

- `lib-packs.txt`: `E298A318C7740EB3129214FB98E49123A0F38DFCD873880C9B5E58C7CB14FE01`
- `PostBuildEvent.ps1`: `10B811659692CA8EECE208423DF5245CB1574448F536E95BC045555546F99CE8`
- Current library-packs directory: `C:\Program Files\dotnet\sdk\10.0.402\FSharp\library-packs`

The 24 packable projects referenced by `dotnet-interactive.slnx` now contain the same Windows `AfterTargets="Pack"` target. The target runs for Debug and Release, links `..\..\PostBuildEvent.ps1`, passes the exact package identity and output path, and never passes `-PushRelease`.

Representative target:

```xml
<ItemGroup>
  <None Include="..\..\PostBuildEvent.ps1" Link="PostBuildEvent.ps1" />
</ItemGroup>

<Target Name="PostPackNugetDeployWindows"
        AfterTargets="Pack"
        Condition="$([MSBuild]::IsOSPlatform('Windows')) and ('$(Configuration)' == 'Debug' or '$(Configuration)' == 'Release')">
  <Exec Command="powershell.exe -NoProfile -ExecutionPolicy Bypass -File &quot;$(MSBuildProjectDirectory)\..\..\PostBuildEvent.ps1&quot; -PackageId &quot;$(PackageId)&quot; -PackageVersion &quot;$(PackageVersion)&quot; -Configuration &quot;$(Configuration)&quot; -ProjectDirectory &quot;$(MSBuildProjectDirectory)&quot; -PackageFilePath &quot;$([System.IO.Path]::Combine('$(PackageOutputPath)', '$(PackageId).$(PackageVersion).nupkg'))&quot;" />
</Target>
```

The two packable sample projects outside `dotnet-interactive.slnx` were deliberately excluded.

A Debug probe used `Microsoft.DotNet.Interactive.Formatting` version `1.0.0-dev.26522.99-debugprobe`. It created both nupkg files, copied the main package to library-packs, printed `NUGET_PUSH_SKIPPED ... reason=configuration-not-release`, and was then removed from both locations.

## Local Interactive library packages

These commands produced the four private host packages. Every pack printed `pushRelease=False` and `NUGET_PUSH_SKIPPED`.

```powershell
$repo = 'G:\coldfar_py\interactive'
$out = "$repo\自主版"
$version = '1.0.0-dev.26522.2'
$projects = @(
  'src\Microsoft.DotNet.Interactive.Formatting\Microsoft.DotNet.Interactive.Formatting.csproj',
  'src\Microsoft.DotNet.Interactive.Documents\Microsoft.DotNet.Interactive.Documents.csproj',
  'src\Microsoft.DotNet.Interactive\Microsoft.DotNet.Interactive.csproj',
  'src\Microsoft.DotNet.Interactive.FSharp\Microsoft.DotNet.Interactive.FSharp.fsproj'
)

$projects | % {
  dotnet pack (join $repo $_) -c Release `
    -p:Version=$version -p:PackageVersion=$version `
    -p:IncludeSymbols=true -p:SymbolPackageFormat=symbols.nupkg `
    -o $out -v:minimal --nologo
  if ($LASTEXITCODE -ne 0) { throw "pack failed: $_" }
}
```

`Directory.Packages.props` uses:

- `FSharp.Core 10.1.402`
- `FSharp.Compiler.Service 43.12.402`
- `System.Security.Cryptography.Pkcs 10.0.13`
- `System.Security.Cryptography.Xml 10.0.13`

The obsolete, unused `PocketLogger.For.ApplicationInsights 0.8.0` reference was removed from `dotnet-interactive.csproj`. Its injected content source was incompatible with `Microsoft.ApplicationInsights 3.2.0`; no repo source called that package API.

## Microsoft.dotnet-interactive and VSIX

Actual command:

```powershell
& 'G:\coldfar_py\interactive\src\dotnet-interactive\build-and-install-dotnet-interactive.ps1' `
  -ToolVersion '1.0.752201' `
  -Configuration Release `
  -OutputDirectory 'G:\coldfar_py\interactive\自主版'
```

The script builds the interface contracts and tool package, creates the VSIX, asserts its required tool version/source/publisher/name, and installs the global tool. When the same version is already installed, it now uninstalls and reinstalls from the local package with `--no-http-cache`; this prevents a rebuilt same-version package from leaving an older executable installed.

Result:

- Global package: `microsoft.dotnet-interactive 1.0.752201`
- Executable version: `1.0.752201+8a5717a85215f4a325554868c86336410cbceae4`
- VSIX: `stable\coldfar-interactive-notebooks-1.0.752201.vsix`
- Build completed with one existing `CS9336` redundant-pattern warning in `HttpRequestParser.cs`; package and VSIX creation succeeded.

## dotnet-dib

Actual command:

```powershell
& 'G:\coldfar_py\interactive\src\dotnet-dib\buildTool.ps1' `
  -Configuration Release `
  -ToolVersion '1.0.752201' `
  -OutputDirectory 'G:\coldfar_py\interactive\自主版'
```

Result:

- Global package: `dotnet-dib 1.0.752201`
- Executable version: `1.0.752201+8a5717a85215f4a325554868c86336410cbceae4`
- Build: 0 warnings, 0 errors

## Deedle.DotNet.Interactive.Extension 0.1.1

The Deedle project uses private, versioned references to:

- `Microsoft.DotNet.Interactive 1.0.0-dev.26522.2`
- `Microsoft.DotNet.Interactive.Formatting 1.0.0-dev.26522.2`
- `Microsoft.DotNet.Interactive.FSharp 1.0.0-dev.26522.2`

Because all three have `PrivateAssets="all"`, the published package exposes only `Deedle 8.1.0` and `FSharp.Core 10.1.402` as NuGet dependencies.

Pack command:

```powershell
dotnet pack `
  'G:\coldfar_py\Deedle.DotNet.Interactive.Extension\src\Deedle.DotNet.Interactive.Extension\Deedle.DotNet.Interactive.Extension.fsproj' `
  -c Release `
  -p:Version=0.1.1 `
  -p:PackageVersion=0.1.1 `
  -p:PublishNuGetAfterPack=false `
  -p:IncludeSymbols=true `
  -p:SymbolPackageFormat=symbols.nupkg `
  -o 'G:\coldfar_py\interactive\自主版' `
  -v:minimal --nologo
```

Authorized NuGet publish command; the canonical root script reads the existing credential internally, so no key appears in argv or this document:

```powershell
& 'G:\coldfar_py\Deedle.DotNet.Interactive.Extension\PostBuildEvent.ps1' `
  -PackageId 'Deedle.DotNet.Interactive.Extension' `
  -PackageVersion '0.1.1' `
  -Configuration Release `
  -ProjectDirectory 'G:\coldfar_py\Deedle.DotNet.Interactive.Extension\src\Deedle.DotNet.Interactive.Extension' `
  -PackageFilePath 'G:\coldfar_py\interactive\自主版\Deedle.DotNet.Interactive.Extension.0.1.1.nupkg' `
  -PushRelease
```

NuGet.Protocol returned `NUGET_PUSH_OK`. The official flat-container index then reported `0.1.1` as the latest version.

## Artifact inventory

| File | Bytes | SHA-256 |
|---|---:|---|
| `Microsoft.DotNet.Interactive.Formatting.1.0.0-dev.26522.2.nupkg` | 70,355 | `19B4FD435206D1C2FAE6798DBEDD3EE5D6D46B32572740465B426368E7D733AC` |
| `Microsoft.DotNet.Interactive.Formatting.1.0.0-dev.26522.2.symbols.nupkg` | 98,078 | `6E94C51A84793E8F1993645AABDC3375E23038C99EFD602CA70FB9447D1E7547` |
| `Microsoft.DotNet.Interactive.Documents.1.0.0-dev.26522.2.nupkg` | 33,026 | `B036B5725CA3848B42F9F9B933D47002AFDC9848AA877E08C20786802107E6E8` |
| `Microsoft.DotNet.Interactive.Documents.1.0.0-dev.26522.2.symbols.nupkg` | 47,259 | `FF89FB24454082D041C338402A8EDE7B2E9055232EED20D99E2315200B8CBBDC` |
| `Microsoft.DotNet.Interactive.1.0.0-dev.26522.2.nupkg` | 451,886 | `33D7CA7ECEE9F8C26FE3C23371701D7BF1E39A2BAC936CE9587460C678014535` |
| `Microsoft.DotNet.Interactive.1.0.0-dev.26522.2.symbols.nupkg` | 608,403 | `3291D09EE56C868FE7DBB0FFEEEAAF69CF7C621AE6E72057150F8D51DFD8ACDD` |
| `Microsoft.DotNet.Interactive.FSharp.1.0.0-dev.26522.2.nupkg` | 209,864 | `CF164B1A4C794CA73193EAC429EAAF317C37CEFE78F783FF8FABBEDB87F33A5A` |
| `Microsoft.DotNet.Interactive.FSharp.1.0.0-dev.26522.2.symbols.nupkg` | 257,523 | `D6BCC28BA0B80F04007644B37FEED9ACD2E58687815470CAB98BAE23943DEA9F` |
| `Microsoft.dotnet-interactive.1.0.752201.nupkg` | 50,345,720 | `858C2ECF5716ACD1AE8B2F6FD8E7525C0F77484F11232307EA18BF72869F7077` |
| `Microsoft.dotnet-interactive.1.0.752201.symbols.nupkg` | 50,345,720 | `975E45A83EDF3B491BF6A2BDBFDF58749A9E84E95D8DECDA4CA7714416148B4D` |
| `dotnet-dib.1.0.752201.nupkg` | 50,439,439 | `7D4B6AB56C6D04803FF513583386B883989CFAC136D6998E1130C40ECA8B166A` |
| `dotnet-dib.1.0.752201.symbols.nupkg` | 50,439,439 | `2CA296EB1C8C8163EAD0B8F3E673005CFC7278B20102BBEC560AA8E07DABE327` |
| `Deedle.DotNet.Interactive.Extension.0.1.1.nupkg` | 48,171 | `3AE8F45D6E48AF6C485915F9525CE651C6BA919D35D1CFB1D1531AA48BCAD6D2` |
| `Deedle.DotNet.Interactive.Extension.0.1.1.symbols.nupkg` | 52,838 | `66B5DF6452E88D838B69B6AADF1D3FA53E297CD0F244D38F80F8AB67AED324CD` |
| `stable\coldfar-interactive-notebooks-1.0.752201.vsix` | 1,999,887 | `BDFE71CD632A63861C01C96D686D499651C06B11610C9240CF28EDE5DA87D485` |

The four tool nupkg files are slightly above 50,000,000 bytes. They remain local until an explicit Git LFS or artifact-tracking decision is made.

## Verification commands

```powershell
dotnet tool list -g | ? { $_ -match 'dotnet-dib|microsoft\.dotnet-interactive' }
& "$HOME\.dotnet\tools\dotnet-dib.exe" --version
& "$HOME\.dotnet\tools\dotnet-interactive.exe" --version

Invoke-RestMethod `
  'https://api.nuget.org/v3-flatcontainer/deedle.dotnet.interactive.extension/index.json' |
  % versions |
  ? { $_ -eq '0.1.1' }
```

No broad test suite was run. Validation consisted of Release build/pack for all delivered packages, Debug copy-only PostBuild probing, VSIX contract assertion in the build script, global tool version/commit checks, Deedle nuspec inspection, and NuGet index verification.