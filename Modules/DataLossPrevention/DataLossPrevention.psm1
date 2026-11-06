function Test-PmDlpDefaultField {
    param([string]$Field, [AllowNull()]$Value)
    switch ($Field) {
        'Type' { return $Value -is [string] -and $Value -ceq 'Dlp' }
        'GlobalListType' { return $Value -is [string] -and $Value -ceq 'None' }
        'PolicyCategory' { return $Value -is [string] -and $Value -ceq 'Unknown' }
        { $_ -in @('PolicyConstraints', 'Locations') } {
            if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) { return $false }
            $parsed = ConvertFrom-Json -InputObject $Value -AsHashtable -NoEnumerate -Depth 100 -ErrorAction Stop
            if ($Field -eq 'Locations') { return $parsed -is [array] -and $parsed.Count -eq 0 }
            if ($parsed -isnot [Collections.IDictionary] -or $parsed.Count -ne 2) { return $false }
            foreach ($key in @('AdministrativeUnit', 'DynamicRiskPrevention')) {
                if (-not $parsed.Contains($key) -or $parsed[$key] -isnot [array] -or $parsed[$key].Count -ne 0) {
                    return $false
                }
            }
            return $true
        }
        default { return $false }
    }
}

function Get-PmDlpSpecification {
    @{
        Kind = 'Dlp'
        Get = 'Get-DlpCompliancePolicy'; New = 'New-DlpCompliancePolicy'
        Set = 'Set-DlpCompliancePolicy'
        Fields = @(
            'Name', 'DisplayName', 'Comment', 'Priority', 'ExchangeLocation',
            'ExchangeSenderMemberOf', 'ExchangeSenderMemberOfException',
            'SharePointLocation', 'SharePointLocationException', 'OneDriveLocation',
            'OneDriveLocationException', 'TeamsLocation', 'TeamsLocationException',
            'EndpointDlpLocation', 'EndpointDlpLocationException', 'PowerBIDlpLocation',
            'PowerBIDlpLocationException'
        )
        SetOnly = @()
        References = @()
        External = @(
            'ExchangeLocation', 'ExchangeSenderMemberOf', 'ExchangeSenderMemberOfException',
            'SharePointLocation', 'SharePointLocationException', 'OneDriveLocation',
            'OneDriveLocationException', 'TeamsLocation', 'TeamsLocationException',
            'EndpointDlpLocation', 'EndpointDlpLocationException', 'PowerBIDlpLocation',
            'PowerBIDlpLocationException'
        )
        Ignored = @(
            'Mode', 'DistributionSyncStatus', 'ObjectClass',
            'OrganizationalUnitRoot', 'PolicyRulesMetaData'
        )
        RuleKind = 'DlpRule'
        SafeMode = 'Disable'
    }

    Export-ModuleMember -Function Get-PmDlpSpecification, Test-PmDlpDefaultField
    Export-ModuleMember -Function Get-PmDlpSpecification
    @{
        Kind = 'DlpRule'
        Get = 'Get-DlpComplianceRule'; New = 'New-DlpComplianceRule'
        Set = 'Set-DlpComplianceRule'
        Fields = @(
            'Name', 'DisplayName', 'Comment', 'Priority', 'Disabled', 'AdvancedRule',
            'ContentContainsSensitiveInformation', 'ExceptIfContentContainsSensitiveInformation',
            'BlockAccess', 'BlockAccessScope', 'AccessScope', 'ExceptIfAccessScope',
            'NotifyUser', 'NotifyPolicyTipCustomText', 'NotifyEmailCustomText',
            'NotifyEmailCustomSubject', 'NotifyAllowOverride', 'NotifyOverrideRequirements',
            'NotifyEmailExchangeIncludeAttachment', 'NotifyEmailOnedriveRemediationActions',
            'NotifyPolicyTipDisplayOption', 'NotifyUserType', 'EnforcePortalAccess',
            'GenerateIncidentReport', 'IncidentReportContent', 'ReportSeverityLevel',
            'GenerateAlert', 'AlertProperties', 'EndpointDlpRestrictions',
            'ContentExtensionMatchesWords', 'ExceptIfContentExtensionMatchesWords',
            'RecipientDomainIs', 'ExceptIfRecipientDomainIs', 'SenderDomainIs',
            'ExceptIfSenderDomainIs', 'From', 'ExceptIfFrom', 'FromMemberOf',
            'ExceptIfFromMemberOf', 'SentTo', 'ExceptIfSentTo', 'SentToMemberOf',
            'ExceptIfSentToMemberOf', 'RestrictAccess'
        )
        SetOnly = @()
        References = @('AdvancedRule', 'ContentContainsSensitiveInformation', 'ExceptIfContentContainsSensitiveInformation')
        External = @(
            'AdvancedRule', 'NotifyUser', 'GenerateIncidentReport', 'GenerateAlert',
            'EndpointDlpRestrictions', 'From', 'ExceptIfFrom', 'FromMemberOf',
            'ExceptIfFromMemberOf', 'SentTo', 'ExceptIfSentTo', 'SentToMemberOf',
            'ExceptIfSentToMemberOf', 'RecipientDomainIs', 'ExceptIfRecipientDomainIs',
            'SenderDomainIs', 'ExceptIfSenderDomainIs', 'RestrictAccess'
        )
        Ignored = @(
            'Policy', 'PolicyId', 'ParentPolicyId', 'ParentPolicyName',
            'ObjectClass', 'OrganizationalUnitRoot'
        )
    }
}
