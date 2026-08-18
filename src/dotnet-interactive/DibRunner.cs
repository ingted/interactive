// Copyright (c) .NET Foundation and contributors. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.DotNet.Interactive.App.CommandLine;
using Microsoft.DotNet.Interactive.Commands;
using Microsoft.DotNet.Interactive.Documents;
using Microsoft.DotNet.Interactive.Events;
using Microsoft.DotNet.Interactive.Formatting;

namespace Microsoft.DotNet.Interactive.App;

public static class DibRunner
{
    public static async Task<int> RunAsync(
        FileInfo notebook,
        string defaultKernelName,
        DirectoryInfo workingDirectory,
        TextWriter standardOutput,
        TextWriter standardError,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(notebook);
        ArgumentException.ThrowIfNullOrWhiteSpace(defaultKernelName);
        ArgumentNullException.ThrowIfNull(workingDirectory);
        ArgumentNullException.ThrowIfNull(standardOutput);
        ArgumentNullException.ThrowIfNull(standardError);

        if (!notebook.Exists)
        {
            await standardError.WriteLineAsync($"Notebook not found: {notebook.FullName}");
            return 2;
        }

        if (!string.Equals(notebook.Extension, ".dib", StringComparison.OrdinalIgnoreCase))
        {
            await standardError.WriteLineAsync($"Expected a .dib notebook: {notebook.FullName}");
            return 2;
        }

        if (!workingDirectory.Exists)
        {
            await standardError.WriteLineAsync($"Working directory not found: {workingDirectory.FullName}");
            return 2;
        }

        Environment.CurrentDirectory = workingDirectory.FullName;

        var startupOptions = new StartupOptions(
            workingDir: workingDirectory,
            defaultKernel: defaultKernelName);

        using var kernel = KernelBuilder.CreateKernel(
            defaultKernelName,
            new ConsoleFrontendEnvironment(),
            startupOptions);

        var commandsWithDiagnostics = new HashSet<KernelCommand>();
        using var eventSubscription = kernel.KernelEvents.Subscribe(
            @event => WriteEvent(
                @event,
                standardOutput,
                standardError,
                commandsWithDiagnostics));

        InteractiveDocument document;

        try
        {
            document = await InteractiveDocument.LoadAsync(
                notebook,
                CreateKernelInfos(kernel));
        }
        catch (Exception exception)
        {
            await standardError.WriteLineAsync(exception.Message);
            return 2;
        }

        foreach (var element in document.Elements)
        {
            cancellationToken.ThrowIfCancellationRequested();

            if (string.Equals(element.KernelName, "markdown", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            var result = await kernel.SendAsync(
                new SubmitCode(element.Contents, element.KernelName),
                cancellationToken);

            if (result.Events.Any(@event => @event is CommandFailed))
            {
                return 1;
            }
        }

        return 0;
    }

    static KernelInfoCollection CreateKernelInfos(CompositeKernel kernel)
    {
        var kernelInfos = new KernelInfoCollection
        {
            DefaultKernelName = kernel.DefaultKernelName
        };

        foreach (var childKernel in kernel.ChildKernels)
        {
            kernelInfos.Add(
                new Documents.KernelInfo(
                    childKernel.Name,
                    languageName: childKernel.KernelInfo.LanguageName,
                    aliases: childKernel.KernelInfo.Aliases));
        }

        kernelInfos.Add(
            new Documents.KernelInfo(
                "markdown",
                languageName: "Markdown",
                aliases: ["md"]));

        return kernelInfos;
    }

    static void WriteEvent(
        KernelEvent @event,
        TextWriter standardOutput,
        TextWriter standardError,
        ISet<KernelCommand> commandsWithDiagnostics)
    {
        switch (@event)
        {
            case StandardOutputValueProduced output:
                WriteFormattedValues(standardOutput, output, terminateLine: false);
                break;

            case StandardErrorValueProduced error:
                WriteFormattedValues(standardError, error, terminateLine: false);
                break;

            case ReturnValueProduced value:
                WriteFormattedValues(standardOutput, value, terminateLine: true);
                break;

            case DisplayedValueProduced displayed:
                WriteFormattedValues(standardOutput, displayed, terminateLine: true);
                break;

            case DisplayedValueUpdated updated:
                WriteFormattedValues(standardOutput, updated, terminateLine: true);
                break;

            case DiagnosticsProduced diagnostics:
                commandsWithDiagnostics.Add(diagnostics.Command);
                WriteFormattedValues(
                    standardError,
                    diagnostics.FormattedDiagnostics,
                    terminateLine: true);
                break;

            case CommandFailed failed:
                if (!commandsWithDiagnostics.Contains(failed.Command))
                {
                    WriteLine(standardError, failed.Message);
                }
                break;
        }
    }

    static void WriteFormattedValues(
        TextWriter writer,
        DisplayEvent displayEvent,
        bool terminateLine) =>
        WriteFormattedValues(writer, displayEvent.FormattedValues, terminateLine);

    static void WriteFormattedValues(
        TextWriter writer,
        System.Collections.Generic.IEnumerable<FormattedValue> formattedValues,
        bool terminateLine)
    {
        var values = formattedValues as FormattedValue[] ?? formattedValues.ToArray();
        var formattedValue = values.FirstOrDefault(value => value.MimeType == PlainTextFormatter.MimeType)
                             ?? values.FirstOrDefault(value => value.MimeType == "text/markdown")
                             ?? values.FirstOrDefault();

        if (formattedValue is null || string.IsNullOrEmpty(formattedValue.Value))
        {
            return;
        }

        if (terminateLine)
        {
            WriteLine(writer, formattedValue.Value);
        }
        else
        {
            writer.Write(formattedValue.Value);
        }
    }

    static void WriteLine(TextWriter writer, string value)
    {
        writer.Write(value);

        if (!value.EndsWith('\n'))
        {
            writer.WriteLine();
        }
    }

    sealed class ConsoleFrontendEnvironment : FrontendEnvironment;
}
