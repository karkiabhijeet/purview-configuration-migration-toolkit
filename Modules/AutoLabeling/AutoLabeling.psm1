function Get-PmAutoLabelingSpecification {
    @{
        Kind = 'AutoLabeling'
        Get = 'Get-AutoSensitivityLabelPolicy'; New = 'New-AutoSensitivityLabelPolicy'
        Set = 'Set-AutoSensitivityLabelPolicy'
        Fields = @(
            'Name', 'Comment', 'ApplySensitivityLabel', 'ExchangeLocation',
            'SharePointLocation', 'SharePointLocationException', 'OneDriveLocation',
            'OneDriveLocationException', 'ExchangeSender', 'ExchangeSenderException',
            'ExchangeSenderMemberOf', 'ExchangeSenderMemberOfException',
            'ExternalMailRightsManagementOwner', 'OverwriteLabel', 'Priority'
        )
        SetOnly = @()
        References = @('ApplySensitivityLabel')
        External = @(
            'ExchangeLocation', 'SharePointLocation', 'SharePointLocationException',
            'OneDriveLocation', 'OneDriveLocationException', 'ExchangeSender',
            'ExchangeSenderException', 'ExchangeSenderMemberOf', 'ExchangeSenderMemberOfException',
            'ExternalMailRightsManagementOwner'
        )
        Ignored = @('Mode')
        RuleKind = 'AutoLabelingRule'
        SafeMode = 'TestWithoutNotifications'
    }
    Export-ModuleMember -Function Get-PmAutoLabelingSpecification
    @{
        Kind = 'AutoLabelingRule'
        Get = 'Get-AutoSensitivityLabelRule'; New = 'New-AutoSensitivityLabelRule'
        Set = 'Set-AutoSensitivityLabelRule'
        Fields = @(
            'Name', 'Comment', 'Workload', 'Disabled', 'Priority', 'AdvancedRule',
            'ContentContainsSensitiveInformation', 'ExceptIfContentContainsSensitiveInformation',
            'AccessScope', 'ExceptIfAccessScope', 'ContentExtensionMatchesWords',
            'ExceptIfContentExtensionMatchesWords', 'DocumentNameMatchesWords',
            'ExceptIfDocumentNameMatchesWords', 'RecipientDomainIs', 'ExceptIfRecipientDomainIs',
            'SenderDomainIs', 'ExceptIfSenderDomainIs', 'From', 'ExceptIfFrom',
            'FromMemberOf', 'ExceptIfFromMemberOf', 'SentTo', 'ExceptIfSentTo',
            'SentToMemberOf', 'ExceptIfSentToMemberOf'
        )
        SetOnly = @()
        References = @('AdvancedRule', 'ContentContainsSensitiveInformation', 'ExceptIfContentContainsSensitiveInformation')
        External = @(
            'AdvancedRule', 'From', 'ExceptIfFrom', 'FromMemberOf', 'ExceptIfFromMemberOf',
            'SentTo', 'ExceptIfSentTo', 'SentToMemberOf', 'ExceptIfSentToMemberOf',
            'RecipientDomainIs', 'ExceptIfRecipientDomainIs', 'SenderDomainIs', 'ExceptIfSenderDomainIs'
        )
        Ignored = @('Policy', 'PolicyId', 'ParentPolicyId')
    }
}
