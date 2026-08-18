// Copyright (c) .NET Foundation and contributors. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

using System;
using System.CommandLine;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using Microsoft.DotNet.Interactive.App;

namespace Microsoft.DotNet.Interactive.Dib.App;

public static class Program
{
    public static async Task<int> Main(string[] args)
    {
        Console.InputEncoding = Encoding.UTF8;
        Console.OutputEncoding = Encoding.UTF8;

        var notebookArgument = new Argument<FileInfo>("notebook")
        {
            Description = "The .dib notebook to execute."
        }.AcceptExistingOnly();

        var defaultKernelOption = new Option<string>("--default-kernel")
        {
            Description = "Kernel used by cells without an explicit #! kernel selector.",
            DefaultValueFactory = _ => "fsharp"
        };
        defaultKernelOption.CompletionSources.Add("fsharp", "csharp", "pwsh", "http");

        var workingDirectoryOption = new Option<DirectoryInfo>("--working-dir")
        {
            Description = "Working directory used while executing the notebook.",
            DefaultValueFactory = _ => new DirectoryInfo(Environment.CurrentDirectory)
        };

        var rootCommand = new RootCommand("Run a .dib polyglot notebook using .NET Interactive.")
        {
            notebookArgument,
            defaultKernelOption,
            workingDirectoryOption
        };

        rootCommand.SetAction(
            async (parseResult, cancellationToken) =>
                await DibRunner.RunAsync(
                    parseResult.GetValue(notebookArgument),
                    parseResult.GetValue(defaultKernelOption),
                    parseResult.GetValue(workingDirectoryOption),
                    Console.Out,
                    Console.Error,
                    cancellationToken));

        return await rootCommand.Parse(args).InvokeAsync();
    }
}
