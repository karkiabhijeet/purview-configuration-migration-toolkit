#Requires -Version 7.4
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$parseErrors = @()
Get-ChildItem -LiteralPath $root -Recurse -File |
    Where-Object Extension -in '.ps1', '.psm1', '.psd1' |
    ForEach-Object {
        $tokens = $null
        $errorsInFile = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errorsInFile)
        $parseErrors += $errorsInFile
    }
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
Test-ModuleManifest -Path (Join-Path $root 'PurviewMigration.psd1') -ErrorAction Stop | Out-Null
Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop
$configuration = New-PesterConfiguration
$configuration.Run.Path = Join-Path $PSScriptRoot 'Migration.Tests.ps1'
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'Detailed'
$result = Invoke-Pester -Configuration $configuration
if ($result.FailedCount -or $result.PassedCount -eq 0) { throw "Validation failed: $($result.FailedCount) failed, $($result.PassedCount) passed." }
