# .NET Interactive 自主維護版

Microsoft 已停止維護並封存原始 `.NET Interactive` / Polyglot Notebooks 專案。本 fork 是提供給仍需使用 F# 與 Deedle notebook 的 workaround，預計持續維護這條使用路徑；其他語言或 Polyglot Notebooks 功能不保證相容或持續維護。

## 目前相容環境

- VS Code `1.133.0`（extension 的 `engines.vscode` 為 `^1.87.0`）
- .NET SDK `10.0.400`
- `Microsoft.dotnet-interactive` `1.0.741801`
- `Deedle.DotNet.Interactive.Extension` `0.1.0-alpha15`

Repository：<https://github.com/ingted/interactive>

## 自主 extension identity 與 stdio 防護

VSIX 使用自己的 extension ID：`ingted.coldfar-interactive-notebooks`。它不再沿用 Marketplace 已標記 deprecated 的 `ms-dotnettools.dotnet-interactive-vscode`，也不會在首次啟動時開啟上游的 deprecation 頁面。部署時不可讓新舊兩個 ID 並存，否則會重複註冊 notebook controller。

啟動 kernel 與 notebook parser 時會設定 `DOTNET_NOLOGO=1`、`DOTNET_CLI_TELEMETRY_OPTOUT=1`；即使外部程序仍把 banner 或其他非協議文字寫到 stdout，也只會送往 diagnostics，不會再當作 JSON envelope 解析而中止 notebook。

## 建置自主版 tool 與 VSIX

更新 `Microsoft.DotNet.Interactive.FSharp` 或其他 kernel 程式碼後，從 repository 任意目錄執行正式建置腳本。腳本預設使用 MSBuild／Arcade 算出的版本，建立同版本的 global tool package 與 VSIX，並安裝該 global tool：

Windows PowerShell 5.1：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "G:\coldfar_py\interactive\src\dotnet-interactive\build-and-install-dotnet-interactive.ps1"
```

PowerShell 7：

```powershell
pwsh -NoProfile -File "G:\coldfar_py\interactive\src\dotnet-interactive\build-and-install-dotnet-interactive.ps1"
```

需要固定版本或只建立產物、不替換 global tool 時：

```powershell
pwsh -NoProfile -File "G:\coldfar_py\interactive\src\dotnet-interactive\build-and-install-dotnet-interactive.ps1" `
    -ToolVersion 1.0.741801 `
    -SkipInstall
```

產物位置：

- `自主版\Microsoft.dotnet-interactive.<version>.nupkg`
- `自主版\stable\coldfar-interactive-notebooks-<version>.vsix`

VSIX 內的 `requiredInteractiveToolVersion` 與 `interactiveToolSource` 會指向本次產生的同版本 nupkg 與 `自主版` 目錄；原始 `package.json` 在封裝後會 byte-for-byte 還原。

建置腳本會先修復 Windows checkout 中的 Git source symlink，再編譯 extension，避免 `src/vscode-common` 只是相對路徑文字檔時誤把舊的 JavaScript 包進 VSIX。

如果 tool nupkg 已成功、只有前端封裝失敗，可以從 VSIX 階段繼續，不必重建 tool：

```powershell
pwsh -NoProfile -File "G:\coldfar_py\interactive\src\dotnet-interactive\build-and-install-dotnet-interactive.ps1" `
    -ToolVersion 1.0.741801 `
    -ReuseToolPackage `
    -SkipInstall
```

## 部署

先關閉所有 VS Code 視窗，避免既有 extension host 鎖住 extension 目錄，再執行：

```powershell
dotnet tool uninstall -g Microsoft.dotnet-interactive
dotnet tool install -g Microsoft.dotnet-interactive --source "G:\coldfar_py\interactive\自主版" --version 1.0.741801
code --uninstall-extension ms-dotnettools.dotnet-interactive-vscode
code --install-extension "G:\coldfar_py\interactive\自主版\stable\coldfar-interactive-notebooks-1.0.741801.vsix" --force
```

安裝後重新啟動 VS Code。Notebook 再載入：

```fsharp
#r "nuget: Deedle.DotNet.Interactive.Extension, 0.1.0-alpha15"

open System
open System.Threading
open Deedle
open Deedle.DotNet.Interactive.Extension

let mutable currentFrame =
    Frame.ofRecords [ {| Time = DateTime.UtcNow; Value = 0 |} ]

let sourceTimer =
    new Timer(
        TimerCallback(fun _ ->
            currentFrame <-
                Frame.ofRecords [ {| Time = DateTime.UtcNow; Value = Random.Shared.Next(100) |} ]),
        null,
        0,
        500)

let dfTimer = printDFFun 500 (fun () -> currentFrame)
```

這個 cell 只需執行一次。之後 `printDFFun` 會更新同一個 cell 的同一塊 output，不會新增 cell，也不會重新執行 cell；`Timer` 建立後已自動開始。停止時：

```fsharp
dfTimer.Dispose()
sourceTimer.Dispose()
```

使用 Notebook 的 **Restart Kernel** 後不必關閉 TAB。Frontend 會在新 kernel client 建立時重新綁定 persistent-display listener；重新執行上面的 cell 即可建立屬於新 kernel 的兩個 timer。

## FSI script 相容性

F# kernel 現在會把 `FsiEvaluationSession` 使用的設定物件公開為標準 root-level `fsi`。Notebook 直接執行或以 `#load` 載入的 `.fsx`，可使用 `fsi.CommandLineArgs`、`fsi.AddPrinter` 等 FSI API。

新 Notebook、空白文件與未攜帶 kernel metadata 的 code cell 預設使用 F#。既有 notebook 若已明確保存 C# 或其他 kernel metadata，仍尊重原設定。

若載入的是長時間執行的 host 腳本，`#load` cell 會保持 running，直到 host 自己結束；這是 host lifecycle，不是載入失敗。

## Persistent display 修改

原始 VS Code frontend 只在 cell 執行期間接收該 command token 的 output；cell 完成後，獨立的 `UpdateDisplayedValue` 不會再被 render。本版讓 notebook controller 持續監聽 `DisplayedValueUpdated`，以相同 display ID 找到既有 output，再透過 VS Code 支援的 notebook execution API 原地替換內容。

同一個 notebook 的更新會依序處理；同一 display ID 若更新速度快於 UI，僅保留最新值，避免 timer 造成無限制排隊。
