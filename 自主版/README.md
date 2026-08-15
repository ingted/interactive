# .NET Interactive 自主維護版

Microsoft 已停止維護並封存原始 `.NET Interactive` / Polyglot Notebooks 專案。本 fork 是提供給仍需使用 F# 與 Deedle notebook 的 workaround，預計持續維護這條使用路徑；其他語言或 Polyglot Notebooks 功能不保證相容或持續維護。

## 目前相容環境

- VS Code `1.133.0`（extension 的 `engines.vscode` 為 `^1.87.0`）
- .NET SDK `10.0.400`
- `Microsoft.dotnet-interactive` `1.0.722303`
- `Deedle.DotNet.Interactive.Extension` `0.1.0-alpha15`

Repository：<https://github.com/ingted/interactive>

## 部署

先關閉所有 VS Code 視窗，避免既有 extension host 鎖住 extension 目錄，再執行：

```powershell
dotnet tool uninstall -g Microsoft.dotnet-interactive
dotnet tool install -g Microsoft.dotnet-interactive --source "G:\coldfar_py\interactive\自主版" --version 1.0.722303
code --install-extension "G:\coldfar_py\interactive\自主版\stable\polyglot-net10-fsharp-default.vsix" --force
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
