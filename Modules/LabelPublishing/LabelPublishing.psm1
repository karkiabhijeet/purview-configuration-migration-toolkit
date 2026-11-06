function Get-PmPublishingSpecification {
    @{
        Kind = 'LabelPublishing'
        Get = 'Get-LabelPolicy'; New = 'New-LabelPolicy'; Set = 'Set-LabelPolicy'
        Fields = @(
            'Name', 'Comment', 'Labels', 'Settings', 'AdvancedSettings',
            'ExchangeLocation', 'ExchangeLocationException', 'ModernGroupLocation',
            'ModernGroupLocationException'
        )
        SetOnly = @('Priority')
        References = @('Labels', 'Settings', 'AdvancedSettings')
        External = @(
            'ExchangeLocation', 'ExchangeLocationException',
            'ModernGroupLocation', 'ModernGroupLocationException'
        )
        Ignored = @('Mode')
    }
    Export-ModuleMember -Function Get-PmPublishingSpecification
}
