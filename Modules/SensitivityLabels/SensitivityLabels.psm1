function Get-PmLabelSpecification {
    @{
        Kind = 'SensitivityLabels'
        Get = 'Get-Label'; New = 'New-Label'; Set = 'Set-Label'
        Fields = @(
            'Name', 'DisplayName', 'Tooltip', 'Comment', 'ContentType', 'ParentId',
            'IsLabelGroup', 'LocaleSettings', 'AdvancedSettings', 'Settings',
            'LabelActions', 'Conditions', 'SchematizedDataCondition',
            'ApplyContentMarkingFooterAlignment', 'ApplyContentMarkingFooterEnabled',
            'ApplyContentMarkingFooterFontColor', 'ApplyContentMarkingFooterFontName',
            'ApplyContentMarkingFooterFontSize', 'ApplyContentMarkingFooterMargin',
            'ApplyContentMarkingFooterText', 'ApplyContentMarkingHeaderAlignment',
            'ApplyContentMarkingHeaderEnabled', 'ApplyContentMarkingHeaderFontColor',
            'ApplyContentMarkingHeaderFontName', 'ApplyContentMarkingHeaderFontSize',
            'ApplyContentMarkingHeaderMargin', 'ApplyContentMarkingHeaderText',
            'ApplyWaterMarkingEnabled', 'ApplyWaterMarkingFontColor',
            'ApplyWaterMarkingFontName', 'ApplyWaterMarkingFontSize',
            'ApplyWaterMarkingLayout', 'ApplyWaterMarkingText',
            'EncryptionEnabled', 'EncryptionProtectionType', 'EncryptionRightsDefinitions',
            'EncryptionDoNotForward', 'EncryptionEncryptOnly', 'EncryptionPromptUser',
            'EncryptionContentExpiredOnDateInDaysOrNever', 'EncryptionOfflineAccessDays',
            'EncryptionDoubleKeyEncryptionUrl', 'DefaultContentLabel'
        )
        SetOnly = @('Priority')
        References = @('ParentId', 'DefaultContentLabel', 'Conditions', 'SchematizedDataCondition', 'Settings', 'AdvancedSettings')
        External = @('EncryptionRightsDefinitions', 'EncryptionDoubleKeyEncryptionUrl')
        Ignored = @('ParentName', 'ParentLabelDisplayName', 'Children', 'IsParent')
    }
    Export-ModuleMember -Function Get-PmLabelSpecification
}
