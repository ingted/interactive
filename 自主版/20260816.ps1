#code --install-extension "G:\coldfar_py\interactive\自主版\stable\polyglot-net10-persistent-display-refresh.vsix" --force


dotnet tool uninstall -g Microsoft.dotnet-interactive


dotnet tool install -g Microsoft.dotnet-interactive `
    --source "G:\coldfar_py\interactive\自主版" `
    --version 1.0.722303


#code --install-extension "G:\coldfar_py\interactive\自主版\stable\polyglot-net10-persistent-display-refresh-fsi.vsix" --force
code --install-extension "G:\coldfar_py\interactive\自主版\stable\polyglot-net10-fsharp-default.vsix" --force