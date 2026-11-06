#Requires -Version 7.4
[CmdletBinding()]
param()

Import-Module (Join-Path $PSScriptRoot 'PurviewMigration.psd1') -Force -ErrorAction Stop
Start-PurviewMigrationWizard
