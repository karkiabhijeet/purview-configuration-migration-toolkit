Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($module in @(
    'Modules\SensitivityLabels\SensitivityLabels.psm1',
    'Modules\AutoLabeling\AutoLabeling.psm1',
    'Modules\LabelPublishing\LabelPublishing.psm1',
    'Modules\DataLossPrevention\DataLossPrevention.psm1',
    'Modules\SensitiveInformationTypes\SensitiveInformationTypes.psm1'
)) {
    Import-Module (Join-Path $PSScriptRoot $module) -Scope Local -Force
}

foreach ($file in @(
    'Modules\Common\Common.ps1',
    'Modules\SensitiveInformationTypes\SensitiveInformationTypes.ps1',
    'Modules\Common\Package.ps1',
    'Modules\Common\Import.ps1',
    'Modules\Common\Wizard.ps1'
)) {
    . (Join-Path $PSScriptRoot $file)
}

$script:PmSpecifications = @{}
foreach ($spec in @(
    Get-PmLabelSpecification
    Get-PmAutoLabelingSpecification
    Get-PmPublishingSpecification
    Get-PmDlpSpecification
    Get-PmSitSpecification
)) {
    $script:PmSpecifications[$spec.Kind] = $spec
}

Export-ModuleMember -Function @(
    'Connect-PurviewMigrationTenant', 'Disconnect-PurviewMigrationTenant',
    'Get-PurviewMigrationSession', 'Get-PurviewMigrationInventory',
    'Export-PurviewMigrationPackage', 'Test-PurviewMigrationPackage',
    'New-PurviewMigrationPlan', 'Import-PurviewMigrationPackage',
    'Test-PurviewMigrationImport', 'Start-PurviewMigrationWizard'
)
