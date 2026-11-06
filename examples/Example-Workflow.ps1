#Requires -Version 7.4
# Synthetic example only. Dot-source to define these functions; neither runs automatically.

function Export-ExamplePurviewConfiguration {
    [CmdletBinding()]
    param(
        [guid]$SourceTenantId,
        [string]$SourceAdmin,
        [Parameter(Mandatory)][string]$NewPackageDirectory
    )
    Import-Module (Join-Path $PSScriptRoot '..\PurviewMigration.psd1')
    $connection = @{ UserPrincipalName = $SourceAdmin }
    if ($PSBoundParameters.ContainsKey('SourceTenantId')) { $connection.TenantId = $SourceTenantId }
    $session = Connect-PurviewMigrationTenant @connection
    Write-Host "Source: $($session.UserPrincipalName), tenant $($session.TenantId)."
    Export-PurviewMigrationPackage -SourceTenantId $session.TenantId `
        -Selection @{ Dlp = @('Demo DLP policy'); LabelPublishing = @('Demo publishing') } `
        -Path $NewPackageDirectory
    Disconnect-PurviewMigrationTenant -Confirm:$false
}

function Preview-ExamplePurviewImport {
    [CmdletBinding()]
    param(
        [guid]$DestinationTenantId,
        [string]$DestinationAdmin,
        [Parameter(Mandatory)][string]$PackageDirectory,
        [Parameter(Mandatory)][string]$ReviewedMappingsPath
    )
    Import-Module (Join-Path $PSScriptRoot '..\PurviewMigration.psd1')
    $connection = @{ UserPrincipalName = $DestinationAdmin }
    if ($PSBoundParameters.ContainsKey('DestinationTenantId')) { $connection.TenantId = $DestinationTenantId }
    $session = Connect-PurviewMigrationTenant @connection
    Write-Host "Destination: $($session.UserPrincipalName), tenant $($session.TenantId)."
    New-PurviewMigrationPlan -Path $PackageDirectory -MappingsPath $ReviewedMappingsPath
    Import-PurviewMigrationPackage -Path $PackageDirectory -MappingsPath $ReviewedMappingsPath `
        -DestinationTenantId $session.TenantId -ConfirmDestinationTenantId $session.TenantId -WhatIf
}
