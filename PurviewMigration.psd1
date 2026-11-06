@{
    RootModule = 'PurviewMigration.psm1'
    ModuleVersion = '0.1.0'
    GUID = 'a4d8929c-9b9e-4eaf-89e9-5b63dd0d1258'
    Author = 'Purview Migration contributors'
    Description = 'Selective, guarded Microsoft Purview configuration export and recreation.'
    PowerShellVersion = '7.4'
    FunctionsToExport = @(
        'Connect-PurviewMigrationTenant', 'Disconnect-PurviewMigrationTenant',
        'Get-PurviewMigrationSession', 'Get-PurviewMigrationInventory',
        'Export-PurviewMigrationPackage', 'Test-PurviewMigrationPackage',
        'New-PurviewMigrationPlan', 'Import-PurviewMigrationPackage',
        'Test-PurviewMigrationImport', 'Start-PurviewMigrationWizard'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
