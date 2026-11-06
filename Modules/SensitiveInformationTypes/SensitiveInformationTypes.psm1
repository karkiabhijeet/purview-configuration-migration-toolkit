function Get-PmSitSpecification {
    @{
        Kind = 'SensitiveInformationTypes'
        Get = 'Get-DlpSensitiveInformationTypeRulePackage'
        New = 'New-DlpSensitiveInformationTypeRulePackage'
        Set = ''; Fields = @(); SetOnly = @(); References = @(); External = @(); Ignored = @()
    }
}
Export-ModuleMember -Function Get-PmSitSpecification
