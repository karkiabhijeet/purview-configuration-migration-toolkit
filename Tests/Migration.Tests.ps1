BeforeDiscovery {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'PurviewMigration.psd1') -Force
}

Describe 'Purview migration contracts and safety' {
    InModuleScope PurviewMigration {
        BeforeAll {
            function Get-ConnectionInformation { [CmdletBinding()] param() }
            function Connect-IPPSSession { [CmdletBinding()] param([string]$UserPrincipalName, [switch]$EnableSearchOnlySession) }
            function Set-TestWizardAnswers {
                param([string[]]$Answers)
                $script:answers = [Collections.Generic.Queue[string]]::new()
                foreach ($answer in $Answers) { $script:answers.Enqueue($answer) }
            }
            function New-PmRequiredFixture { [CmdletBinding()] param([Parameter(Mandatory)][string]$Name) }
            $script:realAssertCommand = (Get-Command Assert-PmCommand).ScriptBlock
            $script:realExport = (Get-Command Export-PurviewMigrationPackage).ScriptBlock
            $script:sourceId = '11111111-1111-1111-1111-111111111111'
            $script:destinationId = '22222222-2222-2222-2222-222222222222'
            $script:labelId = '33333333-3333-3333-3333-333333333333'
            $script:policyId = '44444444-4444-4444-4444-444444444444'
            $script:ruleId = '55555555-5555-5555-5555-555555555555'
            $script:xml = @'
<RulePackage xmlns="http://schemas.microsoft.com/office/2011/mce">
  <RulePack id="66666666-6666-6666-6666-666666666666">
    <Version major="1" minor="0" build="0" revision="0" />
    <Publisher id="77777777-7777-7777-7777-777777777777" />
    <Details defaultLangCode="en-us"><LocalizedDetails langcode="en-us"><PublisherName>Test</PublisherName><Name>Test package</Name><Description>Test</Description></LocalizedDetails></Details>
  </RulePack>
  <Rules><Entity id="88888888-8888-8888-8888-888888888888" patternsProximity="300" recommendedConfidence="85"><Pattern confidenceLevel="85"><IdMatch idRef="TestRegex" /></Pattern></Entity><Regex id="TestRegex">EMP-[0-9]{6}</Regex></Rules>
</RulePackage>
'@
            function New-TestExport {
                param([string]$Root, [hashtable]$Selection = @{ AutoLabeling = @('*') }, [switch]$AllowDlpAlertReview, [switch]$AcknowledgeAlert, [switch]$UseExistingDlpLabels)
                $script:tenant = $script:sourceId
                $null = Export-PurviewMigrationPackage -SourceTenantId $script:sourceId -Selection $Selection -Path $Root -AllowDlpAlertReview:$AllowDlpAlertReview -UseExistingDlpLabels:$UseExistingDlpLabels
                $mappingPath = Join-Path $Root 'mappings.json'
                $mapping = Read-PmJson $mappingPath
                $mapping.DestinationTenantId = $script:destinationId
                foreach ($entry in $mapping.Objects.Values) {
                    $entry.Action = 'Create'
                    $entry.StructuredPayloadReviewed = $true
                    $entry.StructuredPayloadEvidence = 'Synthetic payload reviewed'
                    $entry.PublishingOrderReviewed = $true
                    $entry.PublishingOrderEvidence = 'Accept service ordering; inspect manually after publication'
                }
                if ($AcknowledgeAlert) {
                    foreach ($entry in $mapping.Objects.Values) {
                        if ($entry.ContainsKey('ProtectionAlertReviewed')) {
                            $entry.ProtectionAlertReviewed = $true
                            $entry.ProtectionAlertEvidence = 'Synthetic manual alert review'
                        }
                    }
                }
                foreach ($entry in $mapping.References.Values) {
                    $entry.Value = 'destination-reviewed-value'
                    $entry.Reviewed = $true
                    $entry.Evidence = 'Synthetic test fixture'
                }
                Write-PmJson $mappingPath $mapping
                $script:tenant = $script:destinationId
                return $mappingPath
            }
        }

        BeforeEach {
            $script:tenant = $script:sourceId
            $script:connections = $null
            $script:extraSitIds = @()
            $script:writes = 0
            $script:store = @{}
            $script:source = @{
                SensitivityLabels = @(@{
                    Name = 'Test label'; DisplayName = 'Test label'; Tooltip = 'Test tooltip'
                    Guid = $script:labelId; Identity = $script:labelId; Priority = 0
                })
                AutoLabeling = @(@{
                    Name = 'Test auto'; Identity = $script:policyId; Guid = $script:policyId
                    ApplySensitivityLabel = $script:labelId; SharePointLocation = @('All')
                    Mode = 'Enable'
                })
                AutoLabelingRule = @(@{
                    Name = 'Test auto rule'; Identity = $script:ruleId; Guid = $script:ruleId
                    Workload = 'SharePoint'; Priority = 0
                    ContentContainsSensitiveInformation = @(@{ name = 'U.S. Social Security Number (SSN)'; mincount = '1' })
                })
                LabelPublishing = @(@{
                    Name = 'Test publishing'; Identity = $script:policyId; Guid = $script:policyId
                    Labels = @($script:labelId); ExchangeLocation = @('All')
                })
                Dlp = @(@{
                    Name = 'Test DLP'; Identity = $script:policyId; Guid = $script:policyId
                    SharePointLocation = @('All'); Mode = 'Enable'
                })
                DlpRule = @(@{
                    Name = 'Test DLP rule'; Identity = $script:ruleId; Guid = $script:ruleId
                    AdvancedRule = ('{"Condition":{"ConditionName":"ContentContainsSensitiveInformation","Value":[{"groups":[{"name":"Default","labels":[{"name":"' + $script:labelId + '","type":"Sensitivity"}]}]}]}}')
                    BlockAccess = $true
                })
                SensitiveInformationTypes = @()
            }
            Mock Get-ConnectionInformation {
                if ($null -ne $script:connections) { return $script:connections }
                [pscustomobject]@{
                    State = 'Connected'; IsEopSession = $true; TenantID = $script:tenant
                    TokenStatus = 'Active'; ModulePrefix = ''; ConnectionId = 'test-session'
                    UserPrincipalName = 'admin@example.invalid'
                }
            }
            Mock Assert-PmCommand { [pscustomobject]@{ Name = $Name; Parameters = @{} } }
            Mock Invoke-PmCommand {
                $kind = @($script:PmSpecifications.Keys | Where-Object {
                    $script:PmSpecifications[$_].Get -eq $Name -or
                    $script:PmSpecifications[$_].New -eq $Name -or
                    $script:PmSpecifications[$_].Set -eq $Name
                }) | Select-Object -First 1
                if ($Name -eq 'Get-DlpSensitiveInformationType') {
                    $ids = @($script:extraSitIds)
                    foreach ($sit in @($script:store['SensitiveInformationTypes'] | Where-Object { $null -ne $_ })) {
                        $ids += (Get-PmSitDefinition ([pscustomobject]$sit)).EntityIds
                    }
                    return @($ids | ForEach-Object { [pscustomobject]@{ Id = $_ } })
                }
                if (-not $kind) { throw "Unmocked command $Name." }
                $spec = $script:PmSpecifications[$kind]
                if ($Name -eq $spec.Get) {
                    $items = if ($script:tenant -eq $script:sourceId) { @($script:source[$kind]) } else { @($script:store[$kind]) }
                    $items = @($items | Where-Object { $null -ne $_ })
                    if ($Parameters.Contains('Identity')) {
                        return @($items | Where-Object { $_.Identity -eq $Parameters.Identity -or $_.Guid -eq $Parameters.Identity })
                    }
                    return $items
                }
                if ($Name -eq $spec.New) {
                    $script:writes++
                    $item = @{}
                    foreach ($key in $Parameters.Keys) { $item[$key] = $Parameters[$key] }
                    if ($kind -eq 'SensitiveInformationTypes') {
                        $document = Read-PmRuleXml ([Text.Encoding]::UTF8.GetString($Parameters.FileData))
                        $item = @{
                            Name = $document.SelectSingleNode("/*/*[local-name()='RulePack']//*[local-name()='Name']").InnerText
                            Identity = $document.SelectSingleNode("/*/*[local-name()='RulePack']").GetAttribute('id')
                            SerializedClassificationRuleCollection = $Parameters.FileData
                        }
                        $item.Guid = $item.Identity
                        $script:store[$kind] = @(@($script:store[$kind]) | Where-Object { $null -ne $_ }) + @($item)
                        return [pscustomobject]$item
                    }
                    $item.Identity = [guid]::NewGuid().ToString()
                    $item.Guid = $item.Identity
                    $script:store[$kind] = @(@($script:store[$kind]) | Where-Object { $null -ne $_ }) + @($item)
                    return [pscustomobject]$item
                }
                $script:writes++
                $item = @($script:store[$kind] | Where-Object { $_.Identity -eq $Parameters.Identity })[0]
                foreach ($key in $Parameters.Keys) { if ($key -ne 'Identity') { $item[$key] = $Parameters[$key] } }
            }
        }

        It 'requires exactly one actual compliance connection' {
            $script:connections = @()
            { Get-PurviewMigrationSession } | Should -Throw '*exactly one*'
            $script:connections = @(
                [pscustomobject]@{ State = 'Connected'; IsEopSession = $true },
                [pscustomobject]@{ State = 'Connected'; IsEopSession = $true }
            )
            { Get-PurviewMigrationSession } | Should -Throw '*found 2*'
        }

        It 'lets the wizard exit without authenticating or touching a tenant' {
            Mock Get-Module { [pscustomobject]@{ Version = [version]'3.9.0' } } -ParameterFilter {
                $ListAvailable -and $Name -eq 'ExchangeOnlineManagement'
            }
            Mock Import-Module {} -ParameterFilter { $Name -eq 'ExchangeOnlineManagement' }
            Mock Read-PmChoice { 'q' }
            Mock Connect-PmWizardTenant { throw 'Authentication must not run when exiting.' }
            { Start-PurviewMigrationWizard } | Should -Not -Throw
            Should -Invoke Connect-PmWizardTenant -Times 0
            Should -Invoke Invoke-PmCommand -Times 0
        }

        It 'reprompts invalid wizard choices instead of accepting an unsafe default' {
            $script:answers = [Collections.Generic.Queue[string]]::new()
            $script:answers.Enqueue('invalid')
            $script:answers.Enqueue('n')
            Mock Read-Host { $script:answers.Dequeue() }
            (Read-PmChoice 'Proceed?' @('y', 'n')) | Should -Be 'n'
            Should -Invoke Read-Host -Times 2 -Exactly
        }

        Context 'Guided wizard usability' {
            BeforeEach {
                $script:transcript = [Collections.Generic.List[string]]::new()
                Set-TestWizardAnswers @()
                Mock Write-Host { $script:transcript.Add([string]$Object) }
                Mock Write-Warning { $script:transcript.Add("WARNING: $Message") }
                Mock Read-Host {
                    $script:transcript.Add("PROMPT: $Prompt")
                    if (-not $script:answers.Count) { throw "Unexpected prompt: $Prompt" }
                    $script:answers.Dequeue()
                }
                Mock Get-Module { [pscustomobject]@{ Version = [version]'3.9.0' } } -ParameterFilter {
                    $ListAvailable -and $Name -eq 'ExchangeOnlineManagement'
                }
                Mock Import-Module {} -ParameterFilter { $Name -eq 'ExchangeOnlineManagement' }
                Mock Connect-IPPSSession { $script:connections = $null }
            }

            It 'separates headings and guidance with readable labels and host colors' {
                Write-PmWizardSection 'EXPORT - example'
                Write-PmWizardNote "First note`nSecond note"
                $script:transcript[0] | Should -Match '(?s)-{72}\r?\nEXPORT - example\r?\n-{72}'
                $script:transcript[1] | Should -Be "  - First note`n  - Second note"
                Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $ForegroundColor -eq 'Cyan' }
                Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $ForegroundColor -eq 'Gray' }
            }

            It 'explains the optional source admin email and opens sign-in when it is blank' {
                $script:connections = @()
                Set-TestWizardAnswers @('', 'y')
                (Connect-PmWizardTenant 'Source').TenantId | Should -Be $script:sourceId
                Should -Invoke Connect-IPPSSession -Times 1 -Exactly -ParameterFilter { -not $UserPrincipalName }
                ($script:transcript -join "`n") | Should -Match 'Source admin sign-in email \(optional\)'
                ($script:transcript -join "`n") | Should -Match 'Enter opens Microsoft sign-in'
                ($script:transcript -join "`n") | Should -Match 'exporting FROM \(read-only\)'
                ($script:transcript -join "`n") | Should -Not -Match 'account hint'
            }

            It 'passes the optional destination admin email without treating it as proof of tenant identity' {
                $script:connections = @()
                Mock Connect-IPPSSession { $script:connections = $null; $script:tenant = $script:destinationId }
                Set-TestWizardAnswers @('admin@destination.invalid', 'y')
                (Connect-PmWizardTenant 'Destination' -ExcludedTenantId $script:sourceId).TenantId | Should -Be $script:destinationId
                Should -Invoke Connect-IPPSSession -Times 1 -Exactly -ParameterFilter { $UserPrincipalName -eq 'admin@destination.invalid' }
                ($script:transcript -join "`n") | Should -Match 'importing INTO'
                ($script:transcript -join "`n") | Should -Match 'check before continuing'
                $script:writes | Should -Be 0
            }

            It 'discovers tenant identity after interactive login without a tenant ID or UPN' {
                $script:connections = @()
                $session = Connect-PurviewMigrationTenant
                $session.TenantId | Should -Be $script:sourceId
                Should -Invoke Connect-IPPSSession -Times 1 -Exactly -ParameterFilter { -not $UserPrincipalName }
            }

            It 'retains optional expected-tenant validation and passes a UPN hint' {
                $script:connections = @()
                { Connect-PurviewMigrationTenant -TenantId $script:destinationId -UserPrincipalName 'hint@example.invalid' } | Should -Throw '*Wrong tenant*'
                Should -Invoke Connect-IPPSSession -Times 1 -Exactly -ParameterFilter { $UserPrincipalName -eq 'hint@example.invalid' }
            }

            It 'does not silently replace an existing session on the reusable connection API' {
                { Connect-PurviewMigrationTenant } | Should -Throw '*already exists*'
                Should -Invoke Connect-IPPSSession -Times 0
            }

            It 'confirms an existing source session without asking for a GUID' {
                Set-TestWizardAnswers @('y', 'y')
                (Connect-PmWizardTenant 'Source').TenantId | Should -Be $script:sourceId
                Should -Invoke Connect-IPPSSession -Times 0
                ($script:transcript -join "`n") | Should -Match 'Discovered Source tenant ID'
                ($script:transcript -join "`n") | Should -Not -Match 'PROMPT:.*GUID'
            }

            It 'switches an explicitly rejected identity and discovers the destination' {
                Mock Disconnect-PurviewMigrationTenant { $script:connections = @() }
                Mock Connect-IPPSSession { $script:connections = $null; $script:tenant = $script:destinationId }
                Set-TestWizardAnswers @('y', 'n', 's', '', 'y')
                (Connect-PmWizardTenant 'Destination').TenantId | Should -Be $script:destinationId
                Should -Invoke Disconnect-PurviewMigrationTenant -Times 1 -Exactly
                Should -Invoke Connect-IPPSSession -Times 1 -Exactly
                $script:writes | Should -Be 0
            }

            It 'rejects source as destination and allows cancellation without writes' {
                Set-TestWizardAnswers @('y', 'q')
                { Connect-PmWizardTenant 'Destination' -ExcludedTenantId $script:sourceId } | Should -Throw '*cancelled*'
                ($script:transcript -join "`n") | Should -Match 'SOURCE tenant'
                $script:writes | Should -Be 0
            }

            It 'blocks ambiguous sessions before prompting for reuse' {
                $script:connections = @(
                    [pscustomobject]@{ State = 'Connected'; IsEopSession = $true },
                    [pscustomobject]@{ State = 'Connected'; IsEopSession = $true }
                )
                { Connect-PmWizardTenant 'Source' } | Should -Throw '*found 2*'
                Should -Invoke Read-Host -Times 0
            }

            It 'does not reconnect when an explicit tenant switch cannot verify disconnection' {
                Mock Disconnect-PurviewMigrationTenant { throw 'Compliance connections remain. Use a fresh pwsh process.' }
                Set-TestWizardAnswers @('s')
                { Connect-PmWizardTenant 'Destination' } | Should -Throw '*connections remain*'
                Should -Invoke Connect-IPPSSession -Times 0
                $script:writes | Should -Be 0
            }

            It 'surfaces interactive sign-in cancellation without migration writes' {
                $script:connections = @()
                Mock Connect-IPPSSession { throw [OperationCanceledException]::new('Sign-in cancelled by user') }
                Set-TestWizardAnswers @('')
                { Connect-PmWizardTenant 'Source' } | Should -Throw '*Sign-in cancelled*'
                $script:writes | Should -Be 0
            }

            It 'explains the required new folder before asking and handles invalid or quoted paths' {
                $existing = Join-Path $TestDrive 'already-exists'
                $null = New-Item -ItemType Directory -Path $existing
                $file = Join-Path $TestDrive 'not-a-folder.json'
                Set-Content -LiteralPath $file -Value '{}'
                $newPath = Join-Path $TestDrive 'New export with spaces'
                Set-TestWizardAnswers @('', 'https://example.invalid/export', 'NoSuchDrive:\export', $existing, $file, "`"$newPath`"")
                (Read-PmWizardPath -NewExport) | Should -Be $newPath
                Test-Path -LiteralPath $newPath | Should -BeFalse
                $script:transcript[0] | Should -Match 'tool creates the final folder'
                $script:transcript[0] | Should -Match 'no default'
                $script:transcript[0] | Should -Match 'sensitive'
                Should -Invoke Read-Host -Times 6 -Exactly
            }

            It 'accepts a relative custom export path and displays the resolved absolute path' {
                Set-TestWizardAnswers @('.\relative-export-example')
                $path = Read-PmWizardPath -NewExport
                [IO.Path]::IsPathRooted($path) | Should -BeTrue
                ($script:transcript -join "`n") | Should -Match 'Resolved path:'
                Test-Path -LiteralPath $path | Should -BeFalse
            }

            It 'rejects malformed Windows names and non-filesystem providers without losing the prompt' {
                $newPath = Join-Path $TestDrive 'valid-folder'
                Set-TestWizardAnswers @((Join-Path $TestDrive 'invalid<name'), (Join-Path $TestDrive 'CON'), (Join-Path $TestDrive 'trailing.'), 'Env:\TEMP', $newPath)
                (Read-PmWizardPath -NewExport) | Should -Be $newPath
                Should -Invoke Read-Host -Times 5 -Exactly
                Test-Path -LiteralPath $newPath | Should -BeFalse
            }

            It 'distinguishes existing folders and mappings files and reprompts incorrect types' {
                $folder = Join-Path $TestDrive 'paths'
                $null = New-Item -ItemType Directory -Path $folder
                $file = Join-Path $folder 'mappings.json'
                Set-Content -LiteralPath $file -Value '{}'
                Set-TestWizardAnswers @($file, $folder, $folder, '')
                (Read-PmWizardPath) | Should -Be $folder
                (Read-PmWizardPath -File -Default $file) | Should -Be $file
                Should -Invoke Read-Host -Times 4 -Exactly
            }

            It 'cancels a required input without accepting an automatic value' {
                Set-TestWizardAnswers @('q')
                { Read-PmWizardPath -NewExport } | Should -Throw '*cancelled*'
                $script:writes | Should -Be 0
            }

            It 'reprompts invalid solution numbers and supports comma lists, all and skip' {
                Set-TestWizardAnswers @('invalid', '0', '6', '1,4,4', '*', '')
                $numbers = @(Read-PmWizardSelection 'Solution numbers' 5)
                ($numbers -join ',') | Should -Be '0,3'
                (@(Read-PmWizardSelection 'Objects' 2) -join ',') | Should -Be '0,1'
                @(Read-PmWizardSelection 'Objects' 2 -AllowSkip).Count | Should -Be 0
            }

            It 'guides label naming, display text and priority without remote writes' {
                $root = Join-Path $TestDrive 'guided-label'
                $path = New-TestExport $root @{ SensitivityLabels = @('*') }
                Set-TestWizardAnswers @('y', 'c', 'Destination label', 'Friendly label', 'invalid', '2', 'y')
                (Edit-PmWizardMappings (Read-PmPackage $root) $path (Get-PurviewMigrationSession)) | Should -BeTrue
                $entry = (Read-PmJson $path).Objects["SensitivityLabels:$($script:labelId)"]
                $entry.Name | Should -Be 'Destination label'
                $entry.DisplayName | Should -Be 'Friendly label'
                $entry.Priority | Should -Be 2
                $entry.DestinationId | Should -BeNullOrEmpty
                $script:writes | Should -Be 0
            }

            It 'uses the confirmed destination for new mappings without manual GUID entry' {
                $root = Join-Path $TestDrive 'unbound-mapping'
                $script:source.DlpRule[0].Remove('AdvancedRule')
                $null = Export-PurviewMigrationPackage -SourceTenantId $script:sourceId -Selection @{ Dlp = @('*') } -Path $root
                $path = Join-Path $root 'mappings.json'
                $script:tenant = $script:destinationId
                Set-TestWizardAnswers @('y', 'c', '', 'c', '', 'y')
                (Edit-PmWizardMappings (Read-PmPackage $root) $path (Get-PurviewMigrationSession)) | Should -BeTrue
                (Read-PmJson $path).DestinationTenantId | Should -Be $script:destinationId
                @((Read-PmJson $path).Objects.Values | Where-Object Action -eq 'Create').Count | Should -Be 2
            }

            It 'keeps unbound manual mappings unchanged and explains how to continue' {
                $root = Join-Path $TestDrive 'manual-unbound'
                $null = Export-PurviewMigrationPackage -SourceTenantId $script:sourceId -Selection @{ Dlp = @('*') } -Path $root
                $path = Join-Path $root 'mappings.json'
                $hash = (Get-FileHash -LiteralPath $path).Hash
                $script:tenant = $script:destinationId
                Set-TestWizardAnswers @('n')
                (Edit-PmWizardMappings (Read-PmPackage $root) $path (Get-PurviewMigrationSession)) | Should -BeFalse
                (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
                ($script:transcript -join "`n") | Should -Match "DestinationTenantId.*$($script:destinationId)"
            }

            It 'selects verified existing identities for reuse rather than updating them' {
                $root = Join-Path $TestDrive 'guided-reuse'
                $path = New-TestExport $root @{ SensitivityLabels = @('*') }
                $script:store.SensitivityLabels = @($script:source.SensitivityLabels[0])
                Set-TestWizardAnswers @('y', 'r', '1', 'y')
                (Edit-PmWizardMappings (Read-PmPackage $root) $path (Get-PurviewMigrationSession)) | Should -BeTrue
                $entry = (Read-PmJson $path).Objects["SensitivityLabels:$($script:labelId)"]
                $entry.Action | Should -Be 'Reuse'
                $entry.DestinationId | Should -Be $script:labelId
                $script:writes | Should -Be 0
            }

            It 'reprompts reuse with no matching kind instead of accepting an old Create choice' {
                $root = Join-Path $TestDrive 'no-reuse-inventory'
                $path = New-TestExport $root @{ SensitivityLabels = @('*') }
                Set-TestWizardAnswers @('y', 'r', 'c', '', '', '', 'y')
                (Edit-PmWizardMappings (Read-PmPackage $root) $path (Get-PurviewMigrationSession)) | Should -BeTrue
                $script:answers.Count | Should -Be 0
                (Read-PmJson $path).Objects["SensitivityLabels:$($script:labelId)"].Action | Should -Be 'Create'
                ($script:transcript -join "`n") | Should -Match 'no reuse identity will be invented'
                $script:writes | Should -Be 0
            }

            It 'discards guided name and priority edits when local save is declined' {
                $root = Join-Path $TestDrive 'decline-local-save'
                $path = New-TestExport $root @{ SensitivityLabels = @('*') }
                $hash = (Get-FileHash -LiteralPath $path).Hash
                Set-TestWizardAnswers @('y', 'c', 'Unsaved name', 'Unsaved display', '4', 'n')
                { Edit-PmWizardMappings (Read-PmPackage $root) $path (Get-PurviewMigrationSession) } | Should -Throw '*not saved*'
                (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
                $script:writes | Should -Be 0
            }

            It 'requires explicit validation and concrete evidence for external references' {
                $script:source.AutoLabeling[0].ExchangeLocation = @('source@example.invalid')
                $root = Join-Path $TestDrive 'guided-reference'
                $path = New-TestExport $root
                Set-TestWizardAnswers @('y', 'k', 'k', 'k', 'e', 'destination@example.invalid', 'y', 'Destination admin checked membership and location scope', 'y')
                (Edit-PmWizardMappings (Read-PmPackage $root) $path (Get-PurviewMigrationSession)) | Should -BeTrue
                $entry = (Read-PmJson $path).References['source@example.invalid']
                $entry.Value | Should -Be 'destination@example.invalid'
                $entry.Reviewed | Should -BeTrue
                $entry.Evidence | Should -Match 'checked membership'
                ($script:transcript -join "`n") | Should -Match 'No automatic resource lookup'
            }

            It 'does not save unsaved mapping choices when cancelling reference approval' {
                $script:source.AutoLabeling[0].ExchangeLocation = @('source@example.invalid')
                $root = Join-Path $TestDrive 'cancel-reference'
                $path = New-TestExport $root
                $hash = (Get-FileHash -LiteralPath $path).Hash
                Set-TestWizardAnswers @('y', 'k', 'k', 'k', 'e', 'new@example.invalid', 'q')
                { Edit-PmWizardMappings (Read-PmPackage $root) $path (Get-PurviewMigrationSession) } | Should -Throw '*Cancelled*'
                (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
            }

            It 'hands off complex payload review without automatically approving flags' {
                $root = Join-Path $TestDrive 'manual-payload'
                $path = New-TestExport $root @{ Dlp = @('*') }
                $mapping = Read-PmJson $path
                $entry = $mapping.Objects["DlpRule:$($script:ruleId)"]
                $entry.StructuredPayloadReviewed = $false
                $entry.StructuredPayloadEvidence = ''
                Write-PmJson $path $mapping
                Set-TestWizardAnswers @('n', 'b')
                (Edit-PmWizardMappings (Read-PmPackage $root) $path (Get-PurviewMigrationSession)) | Should -BeFalse
                (Read-PmJson $path).Objects["DlpRule:$($script:ruleId)"].StructuredPayloadReviewed | Should -BeFalse
                ($script:transcript -join "`n") | Should -Match 'StructuredPayloadEvidence'
                ($script:transcript -join "`n") | Should -Match ([regex]::Escape($path))
                $preview = Read-PmJson (Join-Path $root 'last-preview.json')
                $preview.CanImport | Should -BeFalse
                @($preview.BlockingErrors | Where-Object { $_ -match 'StructuredPayloadReviewed' }).Count | Should -BeGreaterThan 0
                $script:writes | Should -Be 0
            }

            It 'reloads an explicitly reviewed complex file without replacing its evidence' {
                $root = Join-Path $TestDrive 'reload-payload'
                $path = New-TestExport $root @{ Dlp = @('*') }
                $original = Read-PmJson $path
                $mapping = Read-PmJson $path
                $mapping.Objects["DlpRule:$($script:ruleId)"].StructuredPayloadReviewed = $false
                Write-PmJson $path $mapping
                Set-TestWizardAnswers @('n', 'c')
                Mock Read-Host {
                    $answer = $script:answers.Dequeue()
                    if ($answer -eq 'c') {
                        $updated = Read-PmJson $path
                        $updated.Objects["DlpRule:$($script:ruleId)"].StructuredPayloadReviewed = $true
                        Write-PmJson $path $updated
                    }
                    $answer
                }
                (Edit-PmWizardMappings (Read-PmPackage $root) $path (Get-PurviewMigrationSession)) | Should -BeTrue
                (Read-PmJson $path).Objects["DlpRule:$($script:ruleId)"].StructuredPayloadEvidence |
                    Should -Be $original.Objects["DlpRule:$($script:ruleId)"].StructuredPayloadEvidence
            }

            It 'requires manual encryption and publishing-settings review without expanding supported fields' {
                $package = @{ Objects = @(
                    @{ Key = 'label'; Kind = 'SensitivityLabels'; Fields = @{ EncryptionEnabled = $true } },
                    @{ Key = 'publishing'; Kind = 'LabelPublishing'; Fields = @{ Priority = 1; Settings = @{ Mandatory = 'true' } } }
                ) }
                $mappings = @{ Objects = @{
                    label = @{ Action = 'Create'; StructuredPayloadReviewed = $false; StructuredPayloadEvidence = '' }
                    publishing = @{ Action = 'Create'; StructuredPayloadReviewed = $false; StructuredPayloadEvidence = ''; PublishingOrderReviewed = $false; PublishingOrderEvidence = '' }
                } }
                $reviews = @(Get-PmWizardManualReviews $package $mappings)
                $reviews.Count | Should -Be 3
                ($reviews -join "`n") | Should -Match 'EncryptionEnabled'
                ($reviews -join "`n") | Should -Match 'PublishingOrderEvidence'
            }

            It 'never rewrites journal-bound mappings even on a guided resume' {
                $root = Join-Path $TestDrive 'immutable-resume'
                $path = New-TestExport $root
                $null = Import-PurviewMigrationPackage -Path $root -MappingsPath $path -DestinationTenantId $script:destinationId -ConfirmDestinationTenantId $script:destinationId -Confirm:$false
                $hash = (Get-FileHash -LiteralPath $path).Hash
                (Edit-PmWizardMappings (Read-PmPackage $root) $path (Get-PurviewMigrationSession)) | Should -BeTrue
                (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
                Should -Invoke Read-Host -Times 0
                ($script:transcript -join "`n") | Should -Match 'READ-ONLY'
                $mapping = Read-PmJson $path
                $mapping.Objects.Values | ForEach-Object { $_.Name += '-changed' }
                Write-PmJson $path $mapping
                { Edit-PmWizardMappings (Read-PmPackage $root) $path (Get-PurviewMigrationSession) } | Should -Throw '*Mappings changed*'
            }

            It 'does not overwrite a different destination binding' {
                $root = Join-Path $TestDrive 'wrong-binding'
                $path = New-TestExport $root
                $hash = (Get-FileHash -LiteralPath $path).Hash
                { Edit-PmWizardMappings (Read-PmPackage $root) $path @{ TenantId = $script:sourceId } } | Should -Throw '*different destination*'
                (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
                Should -Invoke Read-Host -Times 0
            }

            It 'refuses to guess a nonstandard resume journal path' {
                $root = Join-Path $TestDrive 'nonstandard-resume'
                $path = New-TestExport $root
                $package = Read-PmPackage $root
                $mapping = Read-PmJson $path
                $journal = Read-PmJournal $package $mapping (Join-Path $root 'custom.journal.json')
                Write-PmJson (Join-Path $root 'custom.journal.json') $journal
                { Edit-PmWizardMappings $package $path (Get-PurviewMigrationSession) } | Should -Throw '*original -JournalPath*'
                Should -Invoke Read-Host -Times 0
                $script:writes | Should -Be 0
            }

            It 'preserves generated new SIT package IDs during ordinary guided creation' {
                $script:source.SensitiveInformationTypes = @(@{
                    Name = 'Test package'; Identity = '66666666-6666-6666-6666-666666666666'
                    SerializedClassificationRuleCollection = [Text.Encoding]::UTF8.GetBytes($script:xml)
                })
                $root = Join-Path $TestDrive 'guided-sit'
                $path = New-TestExport $root @{ SensitiveInformationTypes = @('*') }
                $id = (Read-PmJson $path).Objects.Values[0].DestinationId
                Set-TestWizardAnswers @('y', 'c', '', 'y')
                (Edit-PmWizardMappings (Read-PmPackage $root) $path (Get-PurviewMigrationSession)) | Should -BeTrue
                (Read-PmJson $path).Objects.Values[0].DestinationId | Should -Be $id
                (Read-PmPackage $root).Objects[0].EntityIds | Should -Contain '88888888-8888-8888-8888-888888888888'
            }

            It 'cancels before guiding mappings when Q is entered' {
                $root = Join-Path $TestDrive 'cancel-guidance'
                $path = New-TestExport $root
                Set-TestWizardAnswers @('q')
                { Edit-PmWizardMappings (Read-PmPackage $root) $path (Get-PurviewMigrationSession) } | Should -Throw '*Cancelled*'
                $script:writes | Should -Be 0
            }

            It 'exports through the real wizard flow without reading or validating unselected rules' {
                $otherPolicyId = '99999999-9999-9999-9999-999999999999'
                $script:otherPolicyId = $otherPolicyId
                $script:source.Dlp = @($script:source.Dlp[0], @{ Name = 'Other DLP'; Identity = $otherPolicyId; Guid = $otherPolicyId; SharePointLocation = @('All'); Mode = 'Enable' })
                $script:rulesByPolicy = @{
                    $script:policyId = @($script:source.DlpRule[0])
                    $otherPolicyId = @(@{ Name = 'Other rule'; Identity = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; AdvancedRule = '{not valid json'; ExternalScenarioDependancies = @{ Wrapper = @('x') } })
                }
                Mock Invoke-PmCommand { @($script:rulesByPolicy[[string]$Parameters.Policy]) } -ParameterFilter { $Name -eq 'Get-DlpComplianceRule' }
                Mock Disconnect-PurviewMigrationTenant { $script:connections = @(); $script:tenant = $script:destinationId }
                $root = Join-Path $TestDrive 'selective wizard export'
                Set-TestWizardAnswers @('1', 'y', 'y', '4', '1', $root, '', 'y', 'q')
                Start-PurviewMigrationWizard
                $script:answers.Count | Should -Be 0
                @((Read-PmPackage $root).Objects | Where-Object Kind -eq 'DlpRule').Count | Should -Be 1
                ($script:transcript -join "`n") | Should -Not -Match 'Operation failed:'
                Should -Invoke Invoke-PmCommand -Times 0 -Exactly -ParameterFilter {
                    $Name -eq 'Get-DlpComplianceRule' -and $Parameters.Policy -eq $script:otherPolicyId
                }
                $script:writes | Should -Be 0
            }

            It 'exports a known source alert identifier without a handoff prompt or acknowledgment' {
                $script:source.DlpRule[0].ExternalScenarioDependancies = @{ ProtectionAlertId = [guid]'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }
                Mock Disconnect-PurviewMigrationTenant { $script:connections = @(); $script:tenant = $script:destinationId }
                $root = Join-Path $TestDrive 'alert wizard export'
                Set-TestWizardAnswers @('1', 'y', 'y', '4', '*', $root, '', 'y', 'q')
                Start-PurviewMigrationWizard
                $script:answers.Count | Should -Be 0
                @((Read-PmPackage $root).Objects | Where-Object { $_.ContainsKey('AlertReview') }).Count | Should -Be 0
                Should -Invoke Read-Host -Times 0 -ParameterFilter { $Prompt -like 'Opt in to staged export*' }
                ($script:transcript -join "`n") | Should -Match 'source ProtectionAlertId response identifier is not copied'
                $script:writes | Should -Be 0
            }

            It 'ignores the known identifier but still reports unsupported rule settings' {
                $script:source.DlpRule[0].ExternalScenarioDependancies = @{ ProtectionAlertId = [guid]'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }
                $script:source.DlpRule[0].UnrecognizedSetting = 'unsupported'
                $root = Join-Path $TestDrive 'mixed wizard blockers'
                Set-TestWizardAnswers @('1', 'y', 'y', '4', '*', $root, '', 'q')
                Start-PurviewMigrationWizard
                $script:answers.Count | Should -Be 0
                Test-Path -LiteralPath $root | Should -BeFalse
                Should -Invoke Read-Host -Times 0 -ParameterFilter { $Prompt -like 'Opt in to staged export*' }
                ($script:transcript -join "`n") | Should -Match 'Operation failed:.*unsupported populated fields: UnrecognizedSetting\.'
                ($script:transcript -join "`n") | Should -Not -Match 'Operation failed:.*unsupported populated fields: ExternalScenarioDependancies'
                $script:writes | Should -Be 0
            }

            It 'finds the existing-label handoff inside a wrapped export exception' {
                $script:source.SensitivityLabels[0].Capabilities = @('synthetic capability')
                Mock Export-PurviewMigrationPackage {
                    if (-not $UseExistingDlpLabels) {
                        $failure = [InvalidOperationException]::new('Synthetic label blocker')
                        $failure.Data['ExistingDlpLabelsOptInAvailable'] = $true
                        $failure.Data['ExistingDlpLabelCount'] = 1
                        throw [Exception]::new('Synthetic PowerShell wrapper', $failure)
                    }
                    & $script:realExport -SourceTenantId $SourceTenantId -Selection $Selection -Path $Path -NamePrefix $NamePrefix -UseExistingDlpLabels:$UseExistingDlpLabels
                }
                $root = Join-Path $TestDrive 'wrapped alert wizard'
                Set-TestWizardAnswers @('1', 'y', 'y', '4', '*', $root, '', 'y', 'n', 'q')
                Start-PurviewMigrationWizard
                $script:answers.Count | Should -Be 0
                ($script:transcript -join "`n") | Should -Not -Match 'Operation failed:'
                @((Read-PmPackage $root).Objects | Where-Object { $_.ContainsKey('ExistingLabelReference') }).Count | Should -Be 1
                $script:writes | Should -Be 0
            }

            It 'exports two selected policies and all eight rules without an alert handoff prompt' {
                $script:secondPolicyId = '99999999-9999-9999-9999-999999999999'
                $script:source.Dlp += @{ Name = 'Second DLP'; Guid = $script:secondPolicyId; SharePointLocation = @('All'); Mode = 'Enable' }
                $script:rulesByPolicy = @{}
                foreach ($policy in $script:source.Dlp) {
                    $count = if ($policy.Guid -eq $script:policyId) { 5 } else { 3 }
                    $script:rulesByPolicy[$policy.Guid] = @(for ($i = 1; $i -le $count; $i++) {
                        @{ Name = "$($policy.Name) rule $i"; Guid = [guid]::NewGuid().ToString()
                            ExternalScenarioDependancies = @{ ProtectionAlertId = [guid]::NewGuid() }; BlockAccess = $true }
                    })
                }
                Mock Invoke-PmCommand { @($script:rulesByPolicy[[string]$Parameters.Policy]) } -ParameterFilter { $Name -eq 'Get-DlpComplianceRule' }
                $root = Join-Path $TestDrive 'two policy alert wizard'
                Set-TestWizardAnswers @('1', 'y', 'y', '4', '1,2', $root, '', 'n', 'q')
                Start-PurviewMigrationWizard
                $script:answers.Count | Should -Be 0
                @((Read-PmPackage $root).Objects | Where-Object Kind -eq 'DlpRule').Count | Should -Be 8
                @((Read-PmPackage $root).Objects | Where-Object { $_.ContainsKey('AlertReview') }).Count | Should -Be 0
                Should -Invoke Read-Host -Times 0 -Exactly -ParameterFilter { $Prompt -like 'Opt in to staged export*' }
                ($script:transcript -join "`n") | Should -Not -Match 'Operation failed:'
                $script:writes | Should -Be 0
            }

            It 'offers existing-label mapping without alert approval and exports no unsupported label configuration' {
                $script:source.DlpRule[0].ExternalScenarioDependancies = @{ ProtectionAlertId = [guid]'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }
                $script:source.SensitivityLabels[0].Capabilities = @('synthetic capability')
                $script:source.SensitivityLabels[0].EncryptionTemplateId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
                $root = Join-Path $TestDrive 'wizard label and alert handoffs'
                Set-TestWizardAnswers @('1', 'y', 'y', '4', '*', $root, '', 'y', 'n', 'q')
                Start-PurviewMigrationWizard
                $script:answers.Count | Should -Be 0
                ($script:transcript -join "`n") | Should -Not -Match 'Operation failed:'
                ($script:transcript -join "`n") | Should -Match 'not additional DLP policies'
                $package = Read-PmPackage $root
                @($package.Objects | Where-Object { $_.ContainsKey('ExistingLabelReference') }).Count | Should -Be 1
                @($package.Objects | Where-Object { $_.ContainsKey('AlertReview') }).Count | Should -Be 0
                $script:writes | Should -Be 0
            }

            It 'retains strict label migration when the existing-label alternative is declined' {
                $script:source.SensitivityLabels[0].Capabilities = @('synthetic capability')
                $root = Join-Path $TestDrive 'wizard labels declined'
                Set-TestWizardAnswers @('1', 'y', 'y', '4', '*', $root, '', 'n', 'q')
                Start-PurviewMigrationWizard
                $script:answers.Count | Should -Be 0
                Test-Path -LiteralPath $root | Should -BeFalse
                ($script:transcript -join "`n") | Should -Match 'Label configuration migration remains required'
                ($script:transcript -join "`n") | Should -Not -Match 'Operation failed:'
                $script:writes | Should -Be 0
            }

            It 'guides existing-label selection and evidence without offering label creation' {
                $script:source.SensitivityLabels[0].Capabilities = @('synthetic capability')
                $root = Join-Path $TestDrive 'wizard existing label mapping'
                $path = New-TestExport $root @{ Dlp = @('*') } -UseExistingDlpLabels
                $script:store.SensitivityLabels = @(@{ Name = 'Destination counterpart'; Guid = $script:labelId; Identity = $script:labelId })
                Set-TestWizardAnswers @('y', 'k', 'r', '1', 'y', 'Checked label meaning and destination protection', 'k', 'y')
                (Edit-PmWizardMappings (Read-PmPackage $root) $path (Get-PurviewMigrationSession)) | Should -BeTrue
                $script:answers.Count | Should -Be 0
                $entry = (Read-PmJson $path).Objects["SensitivityLabels:$($script:labelId)"]
                $entry.Action | Should -Be 'Reuse'
                $entry.ExistingLabelReviewed | Should -BeTrue
                $entry.ExistingLabelEvidence | Should -Match 'Checked label meaning'
                Should -Invoke Read-Host -Times 1 -Exactly -ParameterFilter { $Prompt -like 'R select existing destination label*' }
                $script:writes | Should -Be 0
            }

            It 'still blocks unknown dependency keys without offering an alert opt-in' {
                $script:source.DlpRule[0].ExternalScenarioDependancies = @{ ProtectionAlertId = [guid]'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; UnknownDependency = 'x' }
                $root = Join-Path $TestDrive 'alert wizard declined'
                Set-TestWizardAnswers @('1', 'y', 'y', '4', '*', $root, '', 'q')
                Start-PurviewMigrationWizard
                $script:answers.Count | Should -Be 0
                Test-Path -LiteralPath $root | Should -BeFalse
                ($script:transcript -join "`n") | Should -Match 'Operation failed:.*ExternalScenarioDependancies'
                Should -Invoke Read-Host -Times 0 -ParameterFilter { $Prompt -like 'Opt in to staged export*' }
                ($script:transcript -join "`n") | Should -Not -Match 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            }
            It 'executes a complete DLP export, offline check, declined preview, import and verification transcript' {
                $script:source.DlpRule[0].Remove('AdvancedRule')
                Mock Disconnect-PurviewMigrationTenant { $script:connections = @(); $script:tenant = $script:destinationId }
                $root = Join-Path $TestDrive 'DLP wizard export'
                Set-TestWizardAnswers @(
                    '1', 'y', 'y', '4', '*', $root, '', 'y',
                    '2', '',
                    '3', '', '', '', 'y', 'y', 'c', '', 'c', '', 'y', 'n',
                    '3', '', '', 'y', 'y', 'n', 'y', 'IMPORT',
                    '5', '', '', 'y', 'y', 'q'
                )
                Start-PurviewMigrationWizard
                $script:answers.Count | Should -Be 0
                $script:writes | Should -Be 2
                $script:store.Dlp[0].Mode | Should -Be 'Disable'
                (Read-PmJson (Join-Path $root "import-$($script:destinationId).journal.json")).Status | Should -Be 'Verified'
                Test-Path -LiteralPath (Join-Path $root 'last-preview.json') | Should -BeTrue
                ($script:transcript -join "`n") | Should -Not -Match 'Operation failed:'
                ($script:transcript -join "`n") | Should -Match '4 here means DLP'
                Should -Invoke Read-Host -Times 0 -ParameterFilter { $Prompt -match 'tenant GUID' }
            }

            It 'performs no service or journal writes when execution is declined or confirmation is wrong' {
                $root = Join-Path $TestDrive 'decline-import'
                $path = New-TestExport $root
                Set-TestWizardAnswers @(
                    '3', $root, '', 'y', 'y', 'n', 'n',
                    '3', '', '', 'y', 'y', 'n', 'y', 'wrong',
                    'q'
                )
                Start-PurviewMigrationWizard
                $script:answers.Count | Should -Be 0
                $script:writes | Should -Be 0
                Test-Path -LiteralPath (Join-Path $root "import-$($script:destinationId).journal.json") | Should -BeFalse
                ($script:transcript -join "`n") | Should -Match 'Confirmation did not match'
                ($script:transcript -join "`n") | Should -Not -Match 'Operation failed:'
            }

            It 'validates offline without tenant authentication or service reads' {
                $root = Join-Path $TestDrive 'offline-wizard'
                $null = New-TestExport $root
                $script:offlineServiceReads = 0
                Mock Connect-PmWizardTenant { throw 'Offline validation must not authenticate.' }
                Mock Invoke-PmCommand { $script:offlineServiceReads++; throw 'Offline validation must not read Purview.' }
                Set-TestWizardAnswers @('2', $root, 'q')
                Start-PurviewMigrationWizard
                $script:answers.Count | Should -Be 0
                Should -Invoke Connect-PmWizardTenant -Times 0
                $script:offlineServiceReads | Should -Be 0
                ($script:transcript -join "`n") | Should -Not -Match 'Operation failed:'
            }
            It 'requires a distinct PUBLISH confirmation and warns of user impact' {
                $root = Join-Path $TestDrive 'publish-wizard'
                $path = New-TestExport $root @{ LabelPublishing = @('*') }
                Set-TestWizardAnswers @(
                    '4', $root, '', 'y', 'y', 'n', 'y', 'IMPORT',
                    '4', '', '', 'y', 'y', 'n', 'y', 'PUBLISH',
                    'q'
                )
                Start-PurviewMigrationWizard
                $script:answers.Count | Should -Be 0
                $script:writes | Should -Be 3
                @($script:store.LabelPublishing).Count | Should -Be 1
                ($script:transcript -join "`n") | Should -Match 'Publication exposes labels'
                ($script:transcript -join "`n") | Should -Match 'Confirmation did not match'
                ($script:transcript -join "`n") | Should -Not -Match 'Operation failed:'
            }

            It 'retains object selections when an export filesystem error requires another new folder' {
                $root = Join-Path $TestDrive 'retry-folder'
                $second = Join-Path $TestDrive 'retry-folder-second'
                Mock Export-PurviewMigrationPackage { throw [UnauthorizedAccessException]::new('Synthetic access denied') } -ParameterFilter { $Path -eq $root }
                Mock Export-PurviewMigrationPackage {
                    $null = New-Item -ItemType Directory -Path $Path
                    $steps = Join-Path $Path 'NEXT-STEPS.txt'
                    Set-Content -LiteralPath $steps -Value 'Synthetic export'
                    [pscustomobject]@{ Path = $Path; NextSteps = $steps }
                } -ParameterFilter { $Path -eq $second }
                Set-TestWizardAnswers @('1', 'y', 'y', '4', '*', $root, '', $second, 'n', 'q')
                Start-PurviewMigrationWizard
                $script:answers.Count | Should -Be 0
                Should -Invoke Connect-IPPSSession -Times 0
                Should -Invoke Export-PurviewMigrationPackage -Times 1 -ParameterFilter { $Path -eq $second -and $Selection.Dlp[0] -eq $script:policyId }
                ($script:transcript -join "`n") | Should -Match 'Selections are retained'
                ($script:transcript -join "`n") | Should -Not -Match 'Operation failed:'
            }
        }

        It 'blocks a different tenant than the expected GUID' {
            { Get-PurviewMigrationSession -ExpectedTenantId $script:destinationId } | Should -Throw '*Wrong tenant*'
        }

        It 'blocks expired tokens and prefixed sessions' {
            $script:connections = @([pscustomobject]@{
                State = 'Connected'; IsEopSession = $true; TenantID = $script:sourceId
                TokenStatus = 'Expired'; ModulePrefix = ''; ConnectionId = 'test'
            })
            { Get-PurviewMigrationSession } | Should -Throw '*not active*'
            $script:connections[0].TokenStatus = 'Active'
            $script:connections[0].ModulePrefix = 'Other'
            { Get-PurviewMigrationSession } | Should -Throw '*Prefixed*'
        }

        It 'rejects mandatory parameter omissions without allowing a service prompt' {
            { & $script:realAssertCommand 'New-PmRequiredFixture' @() } | Should -Throw '*missing mandatory*'
            { & $script:realAssertCommand 'New-PmRequiredFixture' @('Name') } | Should -Not -Throw
        }

        It 'blocks incomplete exports instead of silently omitting populated fields' {
            $script:source.SensitivityLabels[0].NewUnsupportedFeature = 'important'
            { Get-PmDefinition 'SensitivityLabels' $script:source.SensitivityLabels[0] } | Should -Throw '*NewUnsupportedFeature*'
        }

        It 'does not silently drop an opaque RuleBlob without a supported adapter' {
            $raw = $script:source.DlpRule[0].Clone()
            $raw.RuleBlob = '<opaque-conditions />'
            { Get-PmDefinition 'DlpRule' $raw } | Should -Throw '*RuleBlob*'
        }

        It 'exports DLP configuration without copying service status, directory or rule-summary metadata' {
            $script:source.Dlp[0].DistributionSyncStatus = 'Success'
            $script:source.Dlp[0].ObjectClass = @('top', 'msExchDlpPolicy')
            $script:source.Dlp[0].OrganizationalUnitRoot = 'example.invalid'
            $script:source.Dlp[0].PolicyRulesMetaData = @(@{ Summary = 'summary-only' })
            $root = Join-Path $TestDrive 'dlp-service-metadata'
            $null = Export-PurviewMigrationPackage -SourceTenantId $script:sourceId `
                -Selection @{ Dlp = @('*') } -Path $root
            $package = Read-PmPackage $root
            $policy = @($package.Objects | Where-Object Kind -eq 'Dlp')[0]
            foreach ($field in @('DistributionSyncStatus', 'ObjectClass', 'OrganizationalUnitRoot', 'PolicyRulesMetaData')) {
                $policy.Fields.ContainsKey($field) | Should -BeFalse
            }
            @($package.Objects | Where-Object Kind -eq 'DlpRule').Count | Should -Be 1
            $policy.Fields.SharePointLocation[0] | Should -Be 'All'
            $script:writes | Should -Be 0
        }

        It 'preserves documented DLP rule notification and portal parameters through import and read-back' {
            $settings = @{
                NotifyEmailExchangeIncludeAttachment = $true
                NotifyEmailOnedriveRemediationActions = 'None'
                NotifyUserType = 'NotSet'
                NotifyPolicyTipDisplayOption = 'Default'
                EnforcePortalAccess = $true
            }
            foreach ($key in $settings.Keys) { $script:source.DlpRule[0][$key] = $settings[$key] }
            $script:source.DlpRule[0].ParentPolicyName = 'Test DLP'
            $script:source.DlpRule[0].ObjectClass = @('top', 'rule')
            $script:source.DlpRule[0].OrganizationalUnitRoot = 'example.invalid'
            $script:source.DlpRule[0].IsAdvancedRule = $true
            $script:source.DlpRule[0].ExternalScenarioDependancies = '[]'
            $root = Join-Path $TestDrive 'dlp-rule-notifications'
            $path = New-TestExport $root @{ Dlp = @('*') }
            $rule = @((Read-PmPackage $root).Objects | Where-Object Kind -eq 'DlpRule')[0]
            foreach ($key in $settings.Keys) { $rule.Fields[$key] | Should -Be $settings[$key] }
            foreach ($key in @('ParentPolicyName', 'ObjectClass', 'OrganizationalUnitRoot', 'IsAdvancedRule', 'ExternalScenarioDependancies')) {
                $rule.Fields.ContainsKey($key) | Should -BeFalse
            }
            $result = Import-PurviewMigrationPackage -Path $root -MappingsPath $path `
                -DestinationTenantId $script:destinationId -ConfirmDestinationTenantId $script:destinationId `
                -VerificationDelaySeconds 0 -Confirm:$false
            $result.Status | Should -Be 'Verified'
            foreach ($key in $settings.Keys) { $script:store.DlpRule[0][$key] | Should -Be $settings[$key] }
            $script:store.Dlp[0].Mode | Should -Be 'Disable'
        }

        It 'blocks nonempty external DLP rule dependencies and reports shape without contents' {
            $script:source.DlpRule[0].ExternalScenarioDependancies = '[{"Scenario":"private-feature"}]'
            $root = Join-Path $TestDrive 'dlp-external-scenario'
            $message = ''
            try {
                $null = Export-PurviewMigrationPackage -SourceTenantId $script:sourceId `
                    -Selection @{ Dlp = @('*') } -Path $root
            } catch { $message = $_.Exception.Message }
            $message | Should -Match 'ExternalScenarioDependancies: string length='
            $message | Should -Not -Match 'private-feature'
            Test-Path -LiteralPath $root | Should -BeFalse
        }

        It 'treats only structurally empty ExternalScenarioDependancies values as empty' {
            foreach ($empty in @($null, '', ' [] ', '{}', @(), @{}, @{ Items = @() }, @{ Value = $null; Inner = @{ List = @() } })) {
                $script:source.DlpRule[0].ExternalScenarioDependancies = $empty
                $definition = Get-PmDefinition 'DlpRule' $script:source.DlpRule[0]
                $definition.UnsupportedFields.Count | Should -Be 0
            }
            foreach ($meaningful in @('[{"Scenario":"x"}]', @{ Items = @('x') }, @{ Count = 0 }, @{ Enabled = $false }, @('x'), $true, $false, 0)) {
                $script:source.DlpRule[0].ExternalScenarioDependancies = $meaningful
                (Get-PmDefinition 'DlpRule' $script:source.DlpRule[0] -AllowUnsupported).UnsupportedFields |
                    Should -Contain 'ExternalScenarioDependancies'
            }
        }

        It 'blocks a populated single-property dependency record and reports only its shape' {
            $script:source.DlpRule[0].ExternalScenarioDependancies = @{ Wrapper = @('private-feature') }
            $root = Join-Path $TestDrive 'dlp-record-dependency'
            $message = ''
            try {
                $null = Export-PurviewMigrationPackage -SourceTenantId $script:sourceId -Selection @{ Dlp = @('*') } -Path $root
            } catch { $message = $_.Exception.Message }
            $message | Should -Match 'ExternalScenarioDependancies: record property count=1'
            $message | Should -Not -Match 'private-feature'
            Test-Path -LiteralPath $root | Should -BeFalse
        }

        It 'exports and imports an empty ProtectionAlertId placeholder after service serialization' {
            $raw = [pscustomobject]@{
                Name = 'Placeholder rule'; Guid = $script:ruleId
                ExternalScenarioDependancies = @{ ProtectionAlertId = [guid]::Empty }
            }
            $wire = [Management.Automation.PSSerializer]::Deserialize([Management.Automation.PSSerializer]::Serialize($raw))
            $script:source.DlpRule = @($wire)
            $root = Join-Path $TestDrive 'dlp-empty-protection-alert'
            $path = New-TestExport $root @{ Dlp = @('*') }
            $rule = @((Read-PmPackage $root).Objects | Where-Object Kind -eq 'DlpRule')[0]
            $rule.Fields.ContainsKey('ExternalScenarioDependancies') | Should -BeFalse
            $result = Import-PurviewMigrationPackage -Path $root -MappingsPath $path `
                -DestinationTenantId $script:destinationId -ConfirmDestinationTenantId $script:destinationId `
                -VerificationDelaySeconds 0 -Confirm:$false
            $result.Status | Should -Be 'Verified'
            $script:store.Dlp[0].Mode | Should -Be 'Disable'
        }

        It 'recognizes only a valid GUID in the exact single ProtectionAlertId response record' {
            foreach ($value in @([guid]::Empty, [guid]::Empty.ToString(), '{00000000-0000-0000-0000-000000000000}', [guid]'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')) {
                $script:source.DlpRule[0].ExternalScenarioDependancies = @{ ProtectionAlertId = $value }
                { Get-PmDefinition 'DlpRule' $script:source.DlpRule[0] } | Should -Not -Throw
            }
            foreach ($value in @(
                @{ ProtectionAlertId = 'invalid' },
                @{ ProtectionAlertId = [guid]::Empty; FutureDependency = [guid]::Empty },
                @{ OtherId = [guid]::Empty }
            )) {
                $script:source.DlpRule[0].ExternalScenarioDependancies = $value
                { Get-PmDefinition 'DlpRule' $script:source.DlpRule[0] } | Should -Throw '*ExternalScenarioDependancies*'
            }
        }

        It 'excludes the source alert identifier without creating a review marker or retaining its value' {
            $script:source.DlpRule[0].ExternalScenarioDependancies = @{
                ProtectionAlertId = [guid]'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            }
            $root = Join-Path $TestDrive 'dlp-real-alert-dependency'
            $null = Export-PurviewMigrationPackage -SourceTenantId $script:sourceId -Selection @{ Dlp = @('*') } -Path $root
            $rule = @((Read-PmPackage $root).Objects | Where-Object Kind -eq 'DlpRule')[0]
            $rule.Fields.ContainsKey('ExternalScenarioDependancies') | Should -BeFalse
            $rule.ContainsKey('AlertReview') | Should -BeFalse
            foreach ($file in 'objects.json', 'mappings.json', 'manifest.json', 'NEXT-STEPS.txt') {
                [IO.File]::ReadAllText((Join-Path $root $file)) | Should -Not -Match 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            }
        }

        Context 'DLP existing-label identity references' {
            BeforeEach {
                $script:source.SensitivityLabels[0].Capabilities = @('synthetic capability')
                $script:source.SensitivityLabels[0].EncryptionLinkedTemplateId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
                $script:source.SensitivityLabels[0].SiteAndGroupProtectionEnabled = $true
            }

            It 'keeps strict export blocked and offers the alternative only for DLP-only selections' {
                foreach ($selection in @(@{ Dlp = @('*') }, @{ Dlp = @('*'); SensitivityLabels = @('*') })) {
                    $failure = $null
                    try { Export-PurviewMigrationPackage -SourceTenantId $script:sourceId -Selection $selection -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString())) }
                    catch { $failure = $_.Exception }
                    $failure.Message | Should -Match 'SensitivityLabels.*Capabilities'
                    [bool]$failure.Data['ExistingDlpLabelsOptInAvailable'] | Should -Be (-not $selection.ContainsKey('SensitivityLabels'))
                }
                { Export-PurviewMigrationPackage -SourceTenantId $script:sourceId -Selection @{ AutoLabeling = @('*') } -Path (Join-Path $TestDrive 'not-dlp') -UseExistingDlpLabels } |
                    Should -Throw '*requires a DLP-only selection*'
                $script:writes | Should -Be 0
            }

            It 'exports only referenced label identities with reuse mappings, not label configuration or parent closure' {
                $parentId = '99999999-9999-9999-9999-999999999999'
                $script:source.SensitivityLabels[0].ParentId = $parentId
                $script:source.SensitivityLabels += @{ Name = 'Unused parent'; Guid = $parentId; Capabilities = @('unsupported') }
                $root = Join-Path $TestDrive 'label-reference-package'
                $result = Export-PurviewMigrationPackage -SourceTenantId $script:sourceId -Selection @{ Dlp = @('*') } -Path $root -UseExistingDlpLabels
                $result.ExistingLabelReferences | Should -Be 1
                $labels = @((Read-PmPackage $root).Objects | Where-Object Kind -eq 'SensitivityLabels')
                $labels.Count | Should -Be 1
                $labels[0].Fields.Count | Should -Be 1
                $labels[0].ExistingLabelReference.Creatable | Should -BeFalse
                @($labels[0].Dependencies).Count | Should -Be 0
                $entry = (Read-PmJson (Join-Path $root 'mappings.json')).Objects[$labels[0].Key]
                $entry.Action | Should -Be 'Reuse'
                $entry.DestinationId | Should -BeNullOrEmpty
                $entry.ExistingLabelReviewed | Should -BeFalse
                [IO.File]::ReadAllText((Join-Path $root 'objects.json')) | Should -Not -Match 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb|Capabilities|Unused parent'
                [IO.File]::ReadAllText((Join-Path $root 'NEXT-STEPS.txt')) | Should -Match 'EXISTING DESTINATION LABELS'
            }

            It 'blocks create attempts and unreviewed, invalid or nonexistent reused labels before any writes' {
                $root = Join-Path $TestDrive 'label-reference-blocks'
                $path = New-TestExport $root @{ Dlp = @('*') } -UseExistingDlpLabels
                $mapping = Read-PmJson $path
                $entry = $mapping.Objects["SensitivityLabels:$($script:labelId)"]
                $entry.Action = 'Reuse'; $entry.DestinationId = $script:labelId
                Write-PmJson $path $mapping
                foreach ($offline in @($true, $false)) {
                    $plan = New-PurviewMigrationPlan -Path $root -MappingsPath $path -Offline:$offline
                    ($plan.BlockingErrors -join "`n") | Should -Match 'ExistingLabelReviewed=true'
                }
                { Import-PurviewMigrationPackage -Path $root -MappingsPath $path -DestinationTenantId $script:destinationId -ConfirmDestinationTenantId $script:destinationId -Confirm:$false } |
                    Should -Throw '*ExistingLabelReviewed*'
                $entry.ExistingLabelReviewed = $true; $entry.ExistingLabelEvidence = 'Reviewed synthetic label'
                $entry.DestinationId = 'not-a-guid'
                Write-PmJson $path $mapping
                ((New-PurviewMigrationPlan -Path $root -MappingsPath $path -Offline).BlockingErrors -join "`n") | Should -Match 'valid existing destination label GUID'
                $entry.DestinationId = $script:labelId
                Write-PmJson $path $mapping
                ((New-PurviewMigrationPlan -Path $root -MappingsPath $path).BlockingErrors -join "`n") | Should -Match 'does not uniquely exist'
                $entry.Action = 'Create'
                Write-PmJson $path $mapping
                ((New-PurviewMigrationPlan -Path $root -MappingsPath $path).BlockingErrors -join "`n") | Should -Match 'requires Action Reuse'
                $definition = @((Read-PmPackage $root).Objects | Where-Object Kind -eq 'SensitivityLabels')[0]
                { Get-PmCreateParameters $definition $entry @{} @{} } | Should -Throw '*Create is forbidden*'
                $script:writes | Should -Be 0
            }

            It 'imports and resumes DLP using reviewed existing labels, remapping conditions without label writes' {
                $root = Join-Path $TestDrive 'label-reference-import'
                $path = New-TestExport $root @{ Dlp = @('*') } -UseExistingDlpLabels
                $destinationLabelId = '99999999-9999-9999-9999-999999999999'
                $script:store.SensitivityLabels = @(@{ Name = 'Reviewed counterpart'; Guid = $destinationLabelId; Identity = $destinationLabelId })
                $mapping = Read-PmJson $path
                $entry = $mapping.Objects["SensitivityLabels:$($script:labelId)"]
                $entry.Action = 'Reuse'; $entry.Name = 'Reviewed counterpart'; $entry.DestinationId = $destinationLabelId
                $entry.ExistingLabelReviewed = $true; $entry.ExistingLabelEvidence = 'Checked destination meaning, scope and protection'
                Write-PmJson $path $mapping
                $result = Import-PurviewMigrationPackage -Path $root -MappingsPath $path -DestinationTenantId $script:destinationId -ConfirmDestinationTenantId $script:destinationId -VerificationDelaySeconds 0 -Confirm:$false
                $result.Status | Should -Be 'ConfigurationVerifiedReusedLabelsNotContentVerified'
                $result.ExistingLabelReferences.Count | Should -Be 1
                $script:store.DlpRule[0].AdvancedRule | Should -Match $destinationLabelId
                $script:store.DlpRule[0].AdvancedRule | Should -Not -Match $script:labelId
                $script:store.Dlp[0].Mode | Should -Be 'Disable'
                @($result.Verification | Where-Object Key -eq "SensitivityLabels:$($script:labelId)")[0].Status | Should -Be 'ReusedExistsNotContentVerified'
                $again = Import-PurviewMigrationPackage -Path $root -MappingsPath $path -DestinationTenantId $script:destinationId -ConfirmDestinationTenantId $script:destinationId -VerificationDelaySeconds 0 -Confirm:$false
                $again.Status | Should -Be $result.Status
                @($script:store.Dlp).Count | Should -Be 1
                @($script:store.DlpRule).Count | Should -Be 1
                @($script:store.SensitivityLabels).Count | Should -Be 1
                Should -Invoke Invoke-PmCommand -Times 0 -ParameterFilter { $Name -in @('New-Label', 'Set-Label') }
            }

            It 'rejects malformed or configuration-bearing label identity markers even when hashes match' {
                $root = Join-Path $TestDrive 'label-reference-marker'
                $path = New-TestExport $root @{ Dlp = @('*') } -UseExistingDlpLabels
                $objects = @(Read-PmJson (Join-Path $root 'objects.json'))
                $label = @($objects | Where-Object Kind -eq 'SensitivityLabels')[0]
                $label.Fields.EncryptionEnabled = $true
                Write-PmJson (Join-Path $root 'objects.json') $objects
                $manifest = Read-PmJson (Join-Path $root 'manifest.json')
                $manifest.Files['objects.json'] = (Get-FileHash -LiteralPath (Join-Path $root 'objects.json') -Algorithm SHA256).Hash
                Write-PmJson (Join-Path $root 'manifest.json') $manifest
                { Read-PmPackage $root } | Should -Throw '*Invalid existing-label identity reference*'
            }

            It 'does not waive unsupported DLP settings when existing-label mapping is selected' {
                $script:source.DlpRule[0].UnknownCondition = 'unsupported'
                $root = Join-Path $TestDrive 'labels do not waive DLP blockers'
                { Export-PurviewMigrationPackage -SourceTenantId $script:sourceId -Selection @{ Dlp = @('*') } -Path $root -UseExistingDlpLabels } |
                    Should -Throw '*UnknownCondition*'
                Test-Path -LiteralPath $root | Should -BeFalse
                $script:writes | Should -Be 0
            }

            It 'keeps alert follow-up pending when importing with existing labels and blocks resume if a label disappears' {
                $script:source.DlpRule[0].ExternalScenarioDependancies = @{ ProtectionAlertId = [guid]'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }
                $root = Join-Path $TestDrive 'existing labels and pending alerts'
                $path = New-TestExport $root @{ Dlp = @('*') } -UseExistingDlpLabels -AllowDlpAlertReview -AcknowledgeAlert
                $script:store.SensitivityLabels = @($script:source.SensitivityLabels[0])
                $mapping = Read-PmJson $path
                $entry = $mapping.Objects["SensitivityLabels:$($script:labelId)"]
                $entry.Action = 'Reuse'; $entry.DestinationId = $script:labelId
                $entry.ExistingLabelReviewed = $true; $entry.ExistingLabelEvidence = 'Reviewed destination label meaning and protection'
                Write-PmJson $path $mapping
                $result = Import-PurviewMigrationPackage -Path $root -MappingsPath $path -DestinationTenantId $script:destinationId -ConfirmDestinationTenantId $script:destinationId -VerificationDelaySeconds 0 -Confirm:$false
                $result.Status | Should -Be 'ConfigurationVerifiedManualAlertReviewRequired'
                $result.ExistingLabelReferences.Count | Should -Be 1
                $result.ManualAlertReview.Count | Should -Be 1
                Should -Invoke Invoke-PmCommand -Times 0 -ParameterFilter { $Name -in @('New-Label', 'Set-Label') }
                $writesBeforeResume = $script:writes
                $script:store.SensitivityLabels = @()
                { Import-PurviewMigrationPackage -Path $root -MappingsPath $path -DestinationTenantId $script:destinationId -ConfirmDestinationTenantId $script:destinationId -VerificationDelaySeconds 0 -Confirm:$false } |
                    Should -Throw '*does not uniquely exist*'
                $script:writes | Should -Be $writesBeforeResume
            }
        }

        Context 'explicit staged DLP protection-alert review' {
            BeforeEach {
                $script:alertGuid = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                $script:source.DlpRule[0].ExternalScenarioDependancies = @{ ProtectionAlertId = [guid]$script:alertGuid }
            }

            It 'preserves alert settings through default import and ignores a different destination response identifier' {
                $settings = @{
                    GenerateAlert = @('admin@example.invalid')
                    AlertProperties = '{"aggregationType":"None"}'
                    ReportSeverityLevel = 'Low'
                    GenerateIncidentReport = @('admin@example.invalid')
                    IncidentReportContent = @('DocumentName', 'RuleDetections')
                }
                foreach ($key in $settings.Keys) { $script:source.DlpRule[0][$key] = $settings[$key] }
                $root = Join-Path $TestDrive 'default alert settings import'
                $path = New-TestExport $root @{ Dlp = @('*') }
                $package = Read-PmPackage $root
                $rule = @($package.Objects | Where-Object Kind -eq 'DlpRule')[0]
                foreach ($key in $settings.Keys) { (Get-PmCanonicalJson $rule.Fields[$key]) | Should -Be (Get-PmCanonicalJson $settings[$key]) }
                $mapping = Read-PmJson $path
                $mapping.Objects[$rule.Key].ContainsKey('ProtectionAlertReviewed') | Should -BeFalse
                foreach ($offline in @($true, $false)) {
                    $plan = New-PurviewMigrationPlan -Path $root -MappingsPath $path -Offline:$offline
                    @($plan.BlockingErrors).Count | Should -Be 0
                    ($plan.Warnings -join "`n") | Should -Match 'read-back does not verify alert delivery'
                    $step = @($plan.Steps | Where-Object Kind -eq 'DlpRule')[0]
                    $step.Parameters.ContainsKey('ExternalScenarioDependancies') | Should -BeFalse
                    $step.Parameters.ContainsKey('ProtectionAlertId') | Should -BeFalse
                }
                $result = Import-PurviewMigrationPackage -Path $root -MappingsPath $path -DestinationTenantId $script:destinationId -ConfirmDestinationTenantId $script:destinationId -VerificationDelaySeconds 0 -Confirm:$false
                $result.Status | Should -Be 'Verified'
                foreach ($key in $settings.Keys) {
                    $expected = if ($key -in @('GenerateAlert', 'GenerateIncidentReport')) { ,@('destination-reviewed-value') } else { ,$settings[$key] }
                    (Get-PmCanonicalJson $script:store.DlpRule[0][$key]) | Should -Be (Get-PmCanonicalJson $expected)
                }
                $script:store.DlpRule[0].ExternalScenarioDependancies = @{ ProtectionAlertId = [guid]'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' }
                @(Test-PurviewMigrationImport -Path $root -MappingsPath $path -VerificationDelaySeconds 0).Status | Should -Not -Contain 'ConfigurationVerifiedManualAlertReviewRequired'
                $again = Import-PurviewMigrationPackage -Path $root -MappingsPath $path -DestinationTenantId $script:destinationId -ConfirmDestinationTenantId $script:destinationId -VerificationDelaySeconds 0 -Confirm:$false
                $again.Status | Should -Be 'Verified'
                @($script:store.DlpRule).Count | Should -Be 1
                $script:store.Dlp[0].Mode | Should -Be 'Disable'
                $script:store.DlpRule[0].ReportSeverityLevel = 'High'
                { Test-PurviewMigrationImport -Path $root -MappingsPath $path -VerificationAttempts 1 -VerificationDelaySeconds 0 } | Should -Throw '*ReportSeverityLevel*'
                Should -Invoke Invoke-PmCommand -Times 0 -ParameterFilter {
                    $Name -in @('New-DlpComplianceRule', 'Set-DlpComplianceRule') -and
                    ($Parameters.Contains('ExternalScenarioDependancies') -or $Parameters.Contains('ProtectionAlertId'))
                }
            }

            It 'exports the exact alert identifier by default without legacy review requirements' {
                $root = Join-Path $TestDrive 'alert-strict'
                $result = Export-PurviewMigrationPackage -SourceTenantId $script:sourceId -Selection @{ Dlp = @('*') } -Path $root
                $result.ManualAlertReviewRules | Should -Be 0
                $rule = @((Read-PmPackage $root).Objects | Where-Object Kind -eq 'DlpRule')[0]
                $rule.ContainsKey('AlertReview') | Should -BeFalse
                $script:writes | Should -Be 0
            }

            It 'lists all unsupported selected objects without blocking on the known alert identifier' {
                $script:source.Dlp[0].UnknownPolicySetting = 'unsupported'
                $script:source.DlpRule[0].UnknownRuleSetting = 'unsupported'
                $root = Join-Path $TestDrive 'all export blockers'
                $failure = $null
                try { $null = Export-PurviewMigrationPackage -SourceTenantId $script:sourceId -Selection @{ Dlp = @('*') } -Path $root }
                catch { $failure = $_.Exception }
                $failure.Message | Should -Match "Dlp 'Test DLP'.*UnknownPolicySetting"
                $failure.Message | Should -Match "DlpRule 'Test DLP rule'.*UnknownRuleSetting"
                $failure.Message | Should -Not -Match 'ExternalScenarioDependancies'
                $failure.Data.Contains('AlertReviewOptInAvailable') | Should -BeFalse
                Test-Path -LiteralPath $root | Should -BeFalse
                $script:writes | Should -Be 0
            }

            It 'never lets the opt-in accept unknown keys, extra keys or invalid GUIDs' {
                foreach ($value in @(
                    @{ ProtectionAlertId = 'invalid' },
                    @{ ProtectionAlertId = $script:alertGuid; Other = [guid]::Empty },
                    @{ OtherId = $script:alertGuid },
                    @{ ProtectionAlertId = @($script:alertGuid) },
                    '[{"ProtectionAlertId":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}]'
                )) {
                    $script:source.DlpRule[0].ExternalScenarioDependancies = $value
                    $root = Join-Path $TestDrive "alert-unknown-$([guid]::NewGuid().ToString('N'))"
                    $failure = $null
                    try { $null = Export-PurviewMigrationPackage -SourceTenantId $script:sourceId -Selection @{ Dlp = @('*') } -Path $root -AllowDlpAlertReview }
                    catch { $failure = $_.Exception }
                    $failure.Message | Should -Match 'ExternalScenarioDependancies'
                    $failure.Message | Should -Not -Match 'an explicit -AllowDlpAlertReview staged export is available'
                    Test-Path -LiteralPath $root | Should -BeFalse
                }
            }

            It 'exports a hashed non-creatable marker without the alert ID or field' {
                $root = Join-Path $TestDrive 'alert-optin-export'
                $path = New-TestExport $root @{ Dlp = @('*') } -AllowDlpAlertReview
                $package = Read-PmPackage $root
                $rule = @($package.Objects | Where-Object Kind -eq 'DlpRule')[0]
                $rule.AlertReview.SourceReferenceSha256 | Should -Be (Get-PmTextHash $script:alertGuid)
                $rule.AlertReview.Creatable | Should -BeFalse
                $rule.AlertReview.Status | Should -Be 'ManualAlertReviewPending'
                $rule.Fields.ContainsKey('ExternalScenarioDependancies') | Should -BeFalse
                foreach ($file in 'objects.json', 'mappings.json', 'NEXT-STEPS.txt', 'manifest.json') {
                    [IO.File]::ReadAllText((Join-Path $root $file)) | Should -Not -Match $script:alertGuid
                }
                [IO.File]::ReadAllText((Join-Path $root 'NEXT-STEPS.txt')) | Should -Match 'MANUAL ALERT REVIEW'
                $mapping = Read-PmJson $path
                $mapping.Objects[$rule.Key].ProtectionAlertReviewed | Should -BeFalse
                $script:writes | Should -Be 0
            }

            It 'blocks offline and online plans and imports until each rule is acknowledged, with no writes' {
                $root = Join-Path $TestDrive 'alert-unacknowledged'
                $path = New-TestExport $root @{ Dlp = @('*') } -AllowDlpAlertReview
                foreach ($offline in $true, $false) {
                    $plan = New-PurviewMigrationPlan -Path $root -MappingsPath $path -Offline:$offline
                    $plan.CanImport | Should -BeFalse
                    ($plan.BlockingErrors -join "`n") | Should -Match 'ProtectionAlertReviewed=true'
                    ($plan.Warnings -join "`n") | Should -Match 'ConfigurationVerifiedManualAlertReviewRequired'
                }
                { Import-PurviewMigrationPackage -Path $root -MappingsPath $path -DestinationTenantId $script:destinationId `
                    -ConfirmDestinationTenantId $script:destinationId -VerificationDelaySeconds 0 -Confirm:$false } |
                    Should -Throw '*ProtectionAlertReviewed*'
                $script:writes | Should -Be 0
            }

            It 'stages import, read-back and resume as manual-alert-pending without duplicates or alert writes' {
                $root = Join-Path $TestDrive 'alert-staged-import'
                $path = New-TestExport $root @{ Dlp = @('*') } -AllowDlpAlertReview -AcknowledgeAlert
                $result = Import-PurviewMigrationPackage -Path $root -MappingsPath $path -DestinationTenantId $script:destinationId `
                    -ConfirmDestinationTenantId $script:destinationId -VerificationDelaySeconds 0 -Confirm:$false
                $result.Status | Should -Be 'ConfigurationVerifiedManualAlertReviewRequired'
                $result.ManualAlertReview.Count | Should -Be 1
                $ruleKey = $result.ManualAlertReview[0]
                $result.Objects[$ruleKey].State | Should -Be 'ConfigurationVerifiedManualAlertReviewRequired'
                @($result.Verification | Where-Object Key -eq $ruleKey).Status | Should -Be 'ConfigurationVerifiedManualAlertReviewRequired'
                @($result.Verification | Where-Object { $_.Status -eq 'Verified' }).Count | Should -Be ($result.Verification.Count - 1)
                $firstWrites = $script:writes
                $firstWrites | Should -BeGreaterThan 0
                $script:store.Dlp[0].Mode | Should -Be 'Disable'
                $script:store.DlpRule[0].ContainsKey('ExternalScenarioDependancies') | Should -BeFalse
                $script:store.DlpRule[0].ContainsKey('ProtectionAlertId') | Should -BeFalse
                $again = Import-PurviewMigrationPackage -Path $root -MappingsPath $path -DestinationTenantId $script:destinationId `
                    -ConfirmDestinationTenantId $script:destinationId -VerificationDelaySeconds 0 -Confirm:$false
                $again.Status | Should -Be 'ConfigurationVerifiedManualAlertReviewRequired'
                @($script:store.Dlp).Count | Should -Be 1
                @($script:store.SensitivityLabels).Count | Should -Be 1
                @($script:store.DlpRule).Count | Should -Be 1
                (Read-PmJson (Join-Path $root "import-$($script:destinationId).journal.json")).Status |
                    Should -Be 'ConfigurationVerifiedManualAlertReviewRequired'
                @(Test-PurviewMigrationImport -Path $root -MappingsPath $path -VerificationDelaySeconds 0).Status |
                    Should -Contain 'ConfigurationVerifiedManualAlertReviewRequired'
            }
        }
        Context 'selective DLP rule reads' {
            BeforeEach {
                $script:otherPolicyId = '99999999-9999-9999-9999-999999999999'
                $script:otherRuleId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                $script:source.Dlp = @(
                    $script:source.Dlp[0]
                    @{ Name = 'Other DLP'; Identity = $script:otherPolicyId; Guid = $script:otherPolicyId; SharePointLocation = @('All'); Mode = 'Enable' }
                )
                $script:rulesByPolicy = @{
                    $script:policyId = @($script:source.DlpRule[0])
                    $script:otherPolicyId = @(@{
                        Name = 'Other rule'; Identity = $script:otherRuleId; Guid = $script:otherRuleId
                        AdvancedRule = '{not valid json'; ExternalScenarioDependancies = @{ Wrapper = @('x') }
                        IsAdvancedRule = $true
                    })
                }
                Mock Invoke-PmCommand { @($script:rulesByPolicy[[string]$Parameters.Policy]) } -ParameterFilter {
                    $Name -eq 'Get-DlpComplianceRule'
                }
            }

            It 'reads rules only for the selected policy and ignores unselected bad rules' {
                $root = Join-Path $TestDrive 'selective-dlp'
                $null = Export-PurviewMigrationPackage -SourceTenantId $script:sourceId -Selection @{ Dlp = @('Test DLP') } -Path $root
                $package = Read-PmPackage $root
                @($package.Objects | Where-Object Kind -eq 'Dlp').Name | Should -Be 'Test DLP'
                @($package.Objects | Where-Object Kind -eq 'DlpRule').Count | Should -Be 1
                Should -Invoke Invoke-PmCommand -Times 1 -Exactly -ParameterFilter {
                    $Name -eq 'Get-DlpComplianceRule' -and $Parameters.Policy -eq $script:policyId
                }
                Should -Invoke Invoke-PmCommand -Times 0 -Exactly -ParameterFilter {
                    $Name -eq 'Get-DlpComplianceRule' -and $Parameters.Policy -eq $script:otherPolicyId
                }
                Should -Invoke Invoke-PmCommand -Times 0 -Exactly -ParameterFilter { $Name -eq 'Get-DlpSensitiveInformationType' }
                $script:writes | Should -Be 0
            }

            It 'selects by source ID and still blocks a selected bad rule' {
                $root = Join-Path $TestDrive 'selected-bad'
                { Export-PurviewMigrationPackage -SourceTenantId $script:sourceId -Selection @{ Dlp = @($script:otherPolicyId) } -Path $root } |
                    Should -Throw "*parent policy 'Other DLP'*"
                Should -Invoke Invoke-PmCommand -Times 0 -Exactly -ParameterFilter {
                    $Name -eq 'Get-DlpComplianceRule' -and $Parameters.Policy -eq $script:policyId
                }
                Test-Path -LiteralPath $root | Should -BeFalse
            }

            It 'blocks selected meaningful dependencies even when another policy is clean' {
                $script:rulesByPolicy[$script:otherPolicyId][0].AdvancedRule = $script:source.DlpRule[0].AdvancedRule
                $root = Join-Path $TestDrive 'selected-dependency'
                { Export-PurviewMigrationPackage -SourceTenantId $script:sourceId -Selection @{ Dlp = @('Other DLP') } -Path $root } |
                    Should -Throw '*ExternalScenarioDependancies: record property count=1*'
                Test-Path -LiteralPath $root | Should -BeFalse
            }

            It 'lists policies for the wizard inventory without reading any rules' {
                $inventory = @(Get-PurviewMigrationInventory -SourceTenantId $script:sourceId -Types @('Dlp'))
                $inventory.Name | Should -Be @('Test DLP', 'Other DLP')
                Should -Invoke Invoke-PmCommand -Times 0 -Exactly -ParameterFilter { $Name -eq 'Get-DlpComplianceRule' }
            }

            It 'still reads every policy rule set for catalog loading without a selection' {
                $script:rulesByPolicy[$script:otherPolicyId][0].AdvancedRule = $script:source.DlpRule[0].AdvancedRule
                $script:rulesByPolicy[$script:otherPolicyId][0].ExternalScenarioDependancies = '[]'
                $null = Get-PmCatalog @('Dlp')
                Should -Invoke Invoke-PmCommand -Times 2 -Exactly -ParameterFilter { $Name -eq 'Get-DlpComplianceRule' }
            }
        }
        It 'reports ExternalScenarioDependancies structure for named policies without values' {
            . (Join-Path (Split-Path $PSScriptRoot -Parent) 'Tools\Get-DlpRuleDependencyShape.ps1') -Policy 'x'
            function Get-DlpCompliancePolicy { [CmdletBinding()] param() }
            function Get-DlpComplianceRule { [CmdletBinding()] param([string]$Policy) }
            $otherId = '99999999-9999-9999-9999-999999999999'
            Mock Get-DlpCompliancePolicy {
                @(@{ Name = 'Test DLP'; Guid = $script:policyId }, @{ Name = 'Other DLP'; Guid = $otherId })
            }
            Mock Get-DlpComplianceRule {
                if ($Policy -eq $script:policyId) {
                    @([pscustomobject]@{
                        Name = 'Rule A'; Guid = $script:ruleId; ParentPolicyName = 'Test DLP'
                        ExternalScenarioDependancies = @{ Wrapper = @('secret-value-123') }
                    })
                } else { throw 'Unselected policy rules must not be read.' }
            }
            $result = @(Get-DlpRuleDependencyShape -Policy 'Test DLP')
            $result.Count | Should -Be 1
            $result[0].PolicyId | Should -Be $script:policyId
            $result[0].ParentMatchesQueriedPolicy | Should -BeTrue
            $shape = $result[0].ExternalScenarioDependanciesShape
            $shape.Kind | Should -Be 'record'
            $shape.PropertyCount | Should -Be 1
            $shape.Empty | Should -BeFalse
            $shape.Properties.Wrapper.Kind | Should -Be 'collection'
            $shape.Properties.Wrapper.Items[0].Length | Should -Be 16
            ($result | ConvertTo-Json -Depth 20) | Should -Not -Match 'secret-value-123'
            Should -Invoke Get-DlpComplianceRule -Times 1 -Exactly
            { Get-DlpRuleDependencyShape -Policy 'Missing' } | Should -Throw '*matched 0 policies*'
        }

        It 'distinguishes an all-empty dependency record from a populated one-key record' {
            . (Join-Path (Split-Path $PSScriptRoot -Parent) 'Tools\Get-DlpRuleDependencyShape.ps1') -Policy 'x'
            (Get-DlpShapeNode @{ Items = @() }).Empty | Should -BeTrue
            (Get-DlpShapeNode @{ Items = @('x') }).Empty | Should -BeFalse
            (Get-DlpShapeNode @{ Flag = $false }).Empty | Should -BeFalse
            (Get-DlpShapeNode ([guid]::Empty)).IsEmptyGuid | Should -BeTrue
            (Get-DlpShapeNode ([guid]'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')).IsEmptyGuid | Should -BeFalse
            (Get-DlpShapeNode '00000000-0000-0000-0000-000000000000').IsEmptyGuid | Should -BeTrue
        }

        It 'does not discard inconsistent or unknown advanced-rule flags' {
            $script:source.DlpRule[0].IsAdvancedRule = $false
            { Get-PmDefinition 'DlpRule' $script:source.DlpRule[0] } | Should -Throw '*IsAdvancedRule*'
            $script:source.DlpRule[0].IsAdvancedRule = 'unknown'
            { Get-PmDefinition 'DlpRule' $script:source.DlpRule[0] } | Should -Throw '*IsAdvancedRule*'
            $script:source.DlpRule[0].IsAdvancedRule = $false
            $script:source.DlpRule[0].Remove('AdvancedRule')
            { Get-PmDefinition 'DlpRule' $script:source.DlpRule[0] } | Should -Not -Throw
        }

        It 'preserves false values for documented DLP rule booleans' {
            $script:source.DlpRule[0].NotifyEmailExchangeIncludeAttachment = $false
            $script:source.DlpRule[0].EnforcePortalAccess = $false
            $definition = Get-PmDefinition 'DlpRule' $script:source.DlpRule[0]
            $definition.Fields.ContainsKey('NotifyEmailExchangeIncludeAttachment') | Should -BeTrue
            $definition.Fields.EnforcePortalAccess | Should -BeFalse
        }

        It 'still blocks ambiguous DLP configuration fields and reports only their value shapes' {
            $script:source.Dlp[0].Type = 'Synthetic private type'
            $script:source.Dlp[0].GlobalListType = 2
            $script:source.Dlp[0].PolicyConstraints = @{ ConfidentialConstraint = 'secret fixture' }
            $script:source.Dlp[0].PolicyCategory = 'Synthetic private category'
            $script:source.Dlp[0].Locations = '[{"Workload":"Applications","Location":"secret fixture"}]'
            $root = Join-Path $TestDrive 'dlp-ambiguous-configuration'
            $message = ''
            try {
                $null = Export-PurviewMigrationPackage -SourceTenantId $script:sourceId `
                    -Selection @{ Dlp = @('*') } -Path $root
            } catch { $message = $_.Exception.Message }
            $message | Should -Match 'unsupported populated fields'
            $message | Should -Match 'PolicyConstraints: record property count=1'
            $message | Should -Match 'Locations: string length='
            $message | Should -Not -Match 'secret fixture|Synthetic private|ConfidentialConstraint'
            Test-Path -LiteralPath $root | Should -BeFalse
            $script:writes | Should -Be 0
        }

        It 'exports and imports the reported DLP defaults without changing policy scope or safe mode' {
            $script:source.Dlp[0].Type = 'Dlp'
            $script:source.Dlp[0].GlobalListType = 'None'
            $script:source.Dlp[0].PolicyConstraints = '{"AdministrativeUnit":[],"DynamicRiskPrevention":[]}'
            $script:source.Dlp[0].PolicyCategory = 'Unknown'
            $script:source.Dlp[0].Locations = '[]'
            $root = Join-Path $TestDrive 'dlp-reported-defaults'
            $path = New-TestExport $root @{ Dlp = @('*') }
            $policy = @((Read-PmPackage $root).Objects | Where-Object Kind -eq 'Dlp')[0]
            foreach ($field in @('Type', 'GlobalListType', 'PolicyConstraints', 'PolicyCategory', 'Locations')) {
                $policy.Fields.ContainsKey($field) | Should -BeFalse
            }
            $result = Import-PurviewMigrationPackage -Path $root -MappingsPath $path `
                -DestinationTenantId $script:destinationId -ConfirmDestinationTenantId $script:destinationId `
                -VerificationDelaySeconds 0 -Confirm:$false
            $result.Status | Should -Be 'Verified'
            $script:store.Dlp[0].SharePointLocation[0] | Should -Be 'All'
            $script:store.Dlp[0].Mode | Should -Be 'Disable'
            $script:store.DlpRule.Count | Should -Be 1
        }

        It 'blocks nondefault DLP <Field> rather than discarding configuration' -ForEach @(
            @{ Field = 'Type'; Value = 'Other' }
            @{ Field = 'GlobalListType'; Value = 'Custom' }
            @{ Field = 'PolicyCategory'; Value = 'Custom' }
            @{ Field = 'Locations'; Value = '[{"Workload":"Applications"}]' }
            @{ Field = 'Locations'; Value = '{}' }
            @{ Field = 'Locations'; Value = 'null' }
            @{ Field = 'PolicyConstraints'; Value = '{"AdministrativeUnit":["unit-id"],"DynamicRiskPrevention":[]}' }
            @{ Field = 'PolicyConstraints'; Value = '{"AdministrativeUnit":[],"DynamicRiskPrevention":["risk"]}' }
            @{ Field = 'PolicyConstraints'; Value = '{"AdministrativeUnit":[],"DynamicRiskPrevention":[],"FutureConstraint":[]}' }
            @{ Field = 'PolicyConstraints'; Value = '{"AdministrativeUnit":null,"DynamicRiskPrevention":[]}' }
        ) {
            $script:source.Dlp[0][$Field] = $Value
            { Get-PmDefinition 'Dlp' $script:source.Dlp[0] } | Should -Throw "*unsupported populated fields: $Field*"
            $script:writes | Should -Be 0
        }

        It 'recognizes reordered empty DLP constraints but rejects malformed JSON explicitly' {
            $script:source.Dlp[0].PolicyConstraints = '{ "DynamicRiskPrevention": [], "AdministrativeUnit": [] }'
            { Get-PmDefinition 'Dlp' $script:source.Dlp[0] } | Should -Not -Throw
            $script:source.Dlp[0].PolicyConstraints = '{"AdministrativeUnit":'
            { Get-PmDefinition 'Dlp' $script:source.Dlp[0] } | Should -Throw
        }

        It 'identifies a malformed DLP policy response without skipping it' {
            $script:source.Dlp = @(@{ UnexpectedResponse = 'Synthetic value that must not appear in diagnostics' })
            { Get-PmCatalog @('Dlp') } | Should -Throw '*Get-DlpCompliancePolicy, kind Dlp, result #1*UnexpectedResponse*export is blocked*'
            try { $null = Get-PmCatalog @('Dlp') } catch {
                $_.Exception.Message | Should -Not -Match 'Synthetic value that must not appear'
            }
            $script:writes | Should -Be 0
        }

        It 'identifies a malformed DLP rule and its parent policy without skipping it' {
            $script:source.DlpRule = @(@{})
            { Get-PmCatalog @('Dlp') } | Should -Throw "*Get-DlpComplianceRule, kind DlpRule, parent policy 'Test DLP', result #1*has no stable identity*"
            $script:writes | Should -Be 0
        }

        It 'identifies malformed dependency reads while exporting selected DLP' {
            $root = Join-Path $TestDrive 'malformed-dependency'
            $script:source.SensitivityLabels = @(@{})
            { Export-PurviewMigrationPackage -SourceTenantId $script:sourceId -Selection @{ Dlp = @('*') } -Path $root } |
                Should -Throw '*Get-Label, kind SensitivityLabels*has no stable identity*'
            Test-Path -LiteralPath $root | Should -BeFalse
            $script:writes | Should -Be 0
        }

        It 'rejects collection and null records explicitly instead of indexing them as identities' {
            { Get-PmObjectId $null } | Should -Throw '*Expected an object record*'
            { Get-PmObjectId @(@{}) } | Should -Throw '*Expected an object record*'
        }

        It 'extracts scalar identities from serialized nested identity objects without recording type names' {
            $raw = [pscustomobject]@{
                Name = 'Nested DLP'
                Identity = [pscustomobject]@{ Guid = [guid]$script:policyId; Identity = 'policy-alias' }
            }
            $wire = [Management.Automation.PSSerializer]::Deserialize([Management.Automation.PSSerializer]::Serialize($raw))
            $definition = Get-PmDefinition 'Dlp' $wire -AllowUnsupported
            $definition.SourceId | Should -Be $script:policyId
            $definition.Aliases | Should -Contain $script:policyId
            $definition.Aliases | Should -Contain 'policy-alias'
            $definition.Aliases | Should -Not -Contain 'System.Collections.Hashtable'
            @($definition.Aliases | Where-Object { $_ -isnot [string] }).Count | Should -Be 0
        }

        It 'never accepts unrecognized identity objects or collections as stable identities' {
            { Get-PmObjectId @{ Name = 'Malformed'; Identity = @{ Unrelated = 'value' } } } |
                Should -Throw '*no stable identity*'
            { Get-PmObjectId @{ Name = 'Malformed'; Identity = @('first', 'second') } } |
                Should -Throw '*no stable identity*'
            (Get-PmObjectId @{ Name = 'Fallback'; Guid = @{}; Identity = 'known-id' }) | Should -Be 'known-id'
        }

        It 'ignores empty GUID sentinels and uses another explicit identity' {
            $definition = Get-PmDefinition 'Dlp' @{
                Name = 'Fallback policy'; Guid = [guid]::Empty; Identity = $script:policyId
            } -AllowUnsupported
            $definition.SourceId | Should -Be $script:policyId
            $definition.Aliases | Should -Not -Contain ([guid]::Empty.ToString())
            (Get-PmObjectId @{ Name = 'Nested'; Identity = @{ Guid = '{00000000-0000-0000-0000-000000000000}'; Id = 'known-id' } }) |
                Should -Be 'known-id'
            { Get-PmObjectId @{ Name = 'No identity'; Guid = [guid]::Empty } } |
                Should -Throw '*no stable identity*'
        }

        It 'retrieves DLP rules using the real identity instead of an empty GUID sentinel' {
            $script:source.Dlp[0].Guid = [guid]::Empty
            $catalog = Get-PmCatalog @('Dlp')
            @($catalog | Where-Object Kind -eq 'Dlp')[0].SourceId | Should -Be $script:policyId
            Should -Invoke Invoke-PmCommand -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'Get-DlpComplianceRule' -and $Parameters.Policy -eq $script:policyId
            }
        }

        It 'rejects excessive identity nesting instead of recursing indefinitely' {
            $nested = @{ Guid = 'known-id' }
            for ($i = 0; $i -lt 9; $i++) { $nested = @{ Identity = $nested } }
            { Get-PmObjectId $nested } | Should -Throw '*nesting exceeds*'
        }

        It 'exports DLP policies and rules whose serialized identities contain explicit nested GUIDs' {
            $script:source.Dlp[0].Remove('Guid')
            $script:source.Dlp[0].Identity = @{ Guid = $script:policyId }
            $script:source.DlpRule[0].Remove('Guid')
            $script:source.DlpRule[0].Identity = @{ Guid = $script:ruleId }
            $root = Join-Path $TestDrive 'nested-identity-export'
            $null = Export-PurviewMigrationPackage -SourceTenantId $script:sourceId -Selection @{ Dlp = @('*') } -Path $root
            $package = Read-PmPackage $root
            @($package.Objects | Where-Object Kind -eq 'Dlp')[0].SourceId | Should -Be $script:policyId
            @($package.Objects | Where-Object Kind -eq 'DlpRule')[0].SourceId | Should -Be $script:ruleId
            ($package.Objects.Aliases -join ',') | Should -Not -Match 'System.Collections.Hashtable'
            $script:writes | Should -Be 0
        }

        It 'matches nested destination identities and verifies read-back by the actual GUID' {
            $record = @{ Name = 'Existing'; Identity = @{ Guid = $script:policyId } }
            @(Find-PmExistingObject @($record) $script:policyId).Count | Should -Be 1
            @(Find-PmExistingObject @($record) 'System.Collections.Hashtable').Count | Should -Be 0
            Mock Invoke-PmCommand { [pscustomobject]@{ Name = 'Existing'; Identity = @{ Guid = $script:policyId } } } -ParameterFilter {
                $Name -eq 'Get-DlpCompliancePolicy'
            }
            $actual = Get-PmVerifiedObject @{ Kind = 'Dlp'; Name = 'Existing' } $script:policyId @{ Name = 'Existing' } 1 0
            $actual.Name | Should -Be 'Existing'
            { Get-PmVerifiedObject @{ Kind = 'Dlp'; Name = 'Existing' } $script:ruleId @{ Name = 'Existing' } 1 0 } |
                Should -Throw '*different identity*'
        }

        It 'verifies a reused rule belongs to its mapped policy using an explicit nested GUID' {
            $script:source.DlpRule[0].Remove('AdvancedRule')
            $root = Join-Path $TestDrive 'nested-parent-identity'
            $path = New-TestExport $root @{ Dlp = @('*') }
            $script:store.Dlp = @(@{ Name = 'Existing policy'; Guid = $script:policyId })
            $script:store.DlpRule = @(@{
                Name = 'Existing rule'; Guid = $script:ruleId; Policy = @{ Guid = $script:policyId }
            })
            $mapping = Read-PmJson $path
            $mapping.Objects["Dlp:$($script:policyId)"].Action = 'Reuse'
            $mapping.Objects["Dlp:$($script:policyId)"].DestinationId = $script:policyId
            $mapping.Objects["DlpRule:$($script:ruleId)"].Action = 'Reuse'
            $mapping.Objects["DlpRule:$($script:ruleId)"].DestinationId = $script:ruleId
            Write-PmJson $path $mapping
            $plan = New-PurviewMigrationPlan -Path $root -MappingsPath $path
            $plan.BlockingErrors -join ' ' | Should -Not -Match 'cannot verify that the reused rule belongs'
            $plan.CanImport | Should -BeTrue
            $script:store.DlpRule[0].Policy.Guid = $script:ruleId
            $plan = New-PurviewMigrationPlan -Path $root -MappingsPath $path
            $plan.CanImport | Should -BeFalse
            $plan.BlockingErrors -join ' ' | Should -Match 'cannot verify that the reused rule belongs'
            $script:writes | Should -Be 0
        }

        It 'exports a selected policy, its rules, and label dependencies with valid hashes' {
            $root = Join-Path $TestDrive 'dependency-export'
            $null = New-TestExport $root
            $package = Read-PmPackage $root
            $package.Objects.Count | Should -Be 3
            @($package.Objects | Where-Object Selected).Count | Should -Be 1
            @($package.Objects.Kind) | Should -Contain 'SensitivityLabels'
            (Test-PurviewMigrationPackage $root).Valid | Should -BeTrue
            $script:writes | Should -Be 0
        }

        It 'does not select all objects for an empty selection' {
            { Export-PurviewMigrationPackage -SourceTenantId $script:sourceId -Selection @{ Dlp = @() } -Path (Join-Path $TestDrive 'empty-selection') } | Should -Throw '*empty*'
        }

        It 'rejects a nonexistent exact selector' {
            { Export-PurviewMigrationPackage -SourceTenantId $script:sourceId -Selection @{ Dlp = @('missing') } -Path (Join-Path $TestDrive 'missing-selection') } | Should -Throw '*No Dlp object*'
        }

        It 'does not block a selected export because of an unrelated unsupported object' {
            $script:source.SensitivityLabels += @(@{
                Name = 'Unrelated'; Identity = 'unrelated-id'; NewUnsupportedFeature = 'unsupported'
                ParentId = 'unresolved-parent'
            })
            $root = Join-Path $TestDrive 'selective-export'
            $null = New-TestExport $root
            (Read-PmPackage $root).Objects.Count | Should -Be 3
        }

        It 'includes parent labels and omits the root empty ParentId sentinel' {
            $parentId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            $script:source.SensitivityLabels[0].ParentId = $parentId
            $script:source.SensitivityLabels += @(@{
                Name = 'Parent'; DisplayName = 'Parent'; Tooltip = 'Parent'
                Identity = $parentId; Guid = $parentId; ParentId = [guid]::Empty
            })
            $root = Join-Path $TestDrive 'hierarchy'
            $null = New-TestExport $root @{ SensitivityLabels = @('Test label') }
            $ordered = Get-PmOrderedObjects (Read-PmPackage $root).Objects
            $ordered.Count | Should -Be 2
            $ordered[0].Name | Should -Be 'Parent'
            $ordered[0].Fields.ContainsKey('ParentId') | Should -BeFalse
        }

        It 'refuses an existing export directory' {
            { Export-PurviewMigrationPackage -SourceTenantId $script:sourceId -Selection @{ Dlp = @('*') } -Path $TestDrive } | Should -Throw '*already exists*'
        }

        It 'detects edited source definitions' {
            $root = Join-Path $TestDrive 'hash-export'
            $null = New-TestExport $root
            Add-Content -LiteralPath (Join-Path $root 'objects.json') -Value ' '
            { Test-PurviewMigrationPackage $root } | Should -Throw '*Hash mismatch*'
        }

        It 'rejects path traversal even if a manifest is edited' {
            $root = Join-Path $TestDrive 'traversal-export'
            $null = New-TestExport $root
            $manifestPath = Join-Path $root 'manifest.json'
            $manifest = Read-PmJson $manifestPath
            $manifest.Files['..\outside.xml'] = 'bad'
            Write-PmJson $manifestPath $manifest
            { Test-PurviewMigrationPackage $root } | Should -Throw '*Unsafe*'
        }

        It 'blocks source tenant reuse in mappings' {
            $root = Join-Path $TestDrive 'same-tenant'
            $path = New-TestExport $root
            $mapping = Read-PmJson $path
            $mapping.DestinationTenantId = $script:sourceId
            Write-PmJson $path $mapping
            { New-PurviewMigrationPlan -Path $root -MappingsPath $path -Offline } | Should -Throw '*different*'
        }

        It 'requires explicit per-object create/reuse decisions' {
            $root = Join-Path $TestDrive 'review-action'
            $path = New-TestExport $root
            $mapping = Read-PmJson $path
            @($mapping.Objects.Values)[0].Action = 'Review'
            Write-PmJson $path $mapping
            $plan = New-PurviewMigrationPlan -Path $root -MappingsPath $path
            $plan.CanImport | Should -BeFalse
            $plan.BlockingErrors -join ' ' | Should -Match 'choose Action'
        }

        It 'produces offline previews without claiming online readiness' {
            $root = Join-Path $TestDrive 'offline-preview'
            $path = New-TestExport $root
            $plan = New-PurviewMigrationPlan -Path $root -MappingsPath $path -Offline
            $plan.Online | Should -BeFalse
            $plan.CanImport | Should -BeFalse
            $plan.Steps.Count | Should -Be 3
            $script:writes | Should -Be 0
        }

        It 'requires reviewed external mappings and validation evidence' {
            $script:source.AutoLabeling[0].SharePointLocation = @('https://source.example.invalid/sites/demo')
            $root = Join-Path $TestDrive 'external-reference'
            $path = New-TestExport $root
            $mapping = Read-PmJson $path
            $mapping.References.Values | ForEach-Object { $_.Reviewed = $false }
            Write-PmJson $path $mapping
            (New-PurviewMigrationPlan -Path $root -MappingsPath $path).CanImport | Should -BeFalse
        }

        It 'requires explicit review of structured advanced rule payloads' {
            $root = Join-Path $TestDrive 'opaque-review'
            $path = New-TestExport $root @{ Dlp = @('*') }
            $mapping = Read-PmJson $path
            $mapping.Objects["DlpRule:$($script:ruleId)"].StructuredPayloadReviewed = $false
            Write-PmJson $path $mapping
            $plan = New-PurviewMigrationPlan -Path $root -MappingsPath $path
            $plan.CanImport | Should -BeFalse
            $plan.BlockingErrors -join ' ' | Should -Match 'StructuredPayloadReviewed'
        }

        It 'rejects a journal path that could overwrite definitions' {
            $root = Join-Path $TestDrive 'journal-path'
            $path = New-TestExport $root
            { New-PurviewMigrationPlan -Path $root -MappingsPath $path -JournalPath (Join-Path $root 'objects.json') } | Should -Throw '*must end in*'
        }

        It 'blocks existing destination-name conflicts' {
            $root = Join-Path $TestDrive 'conflict'
            $path = New-TestExport $root
            $script:store.SensitivityLabels = @(@{ Name = 'Test label'; Identity = 'existing'; Guid = 'existing' })
            $plan = New-PurviewMigrationPlan -Path $root -MappingsPath $path
            $plan.CanImport | Should -BeFalse
            $plan.BlockingErrors -join ' ' | Should -Match 'name already exists'
        }

        It 'does not permit adding rules to a reused pre-existing policy' {
            $root = Join-Path $TestDrive 'reused-parent'
            $path = New-TestExport $root
            $mapping = Read-PmJson $path
            $policyKey = "AutoLabeling:$($script:policyId)"
            $mapping.Objects[$policyKey].Action = 'Reuse'
            $mapping.Objects[$policyKey].DestinationId = 'existing-policy'
            Write-PmJson $path $mapping
            $script:store.AutoLabeling = @(@{ Name = 'Test auto'; Identity = 'existing-policy' })
            $plan = New-PurviewMigrationPlan -Path $root -MappingsPath $path
            $plan.CanImport | Should -BeFalse
            $plan.BlockingErrors -join ' ' | Should -Match 'cannot add a new rule'
        }

        It 'runs WhatIf with zero remote or journal writes' {
            $root = Join-Path $TestDrive 'whatif'
            $path = New-TestExport $root
            $plan = Import-PurviewMigrationPackage -Path $root -MappingsPath $path `
                -DestinationTenantId $script:destinationId -ConfirmDestinationTenantId $script:destinationId -WhatIf
            $plan.CanImport | Should -BeTrue
            $script:writes | Should -Be 0
            Test-Path -LiteralPath $plan.JournalPath | Should -BeFalse
        }

        It 'requires matching typed destination confirmation' {
            { Import-PurviewMigrationPackage -Path 'unused' -MappingsPath 'unused' `
                -DestinationTenantId $script:destinationId -ConfirmDestinationTenantId $script:sourceId } | Should -Throw '*confirmation*'
        }

        It 'creates dependency-linked auto-labeling objects in simulation and verifies them' {
            $root = Join-Path $TestDrive 'auto-import'
            $path = New-TestExport $root
            $result = Import-PurviewMigrationPackage -Path $root -MappingsPath $path `
                -DestinationTenantId $script:destinationId -ConfirmDestinationTenantId $script:destinationId -VerificationDelaySeconds 0 -Confirm:$false
            $result.Status | Should -Be 'Verified'
            $script:store.AutoLabeling[0].Mode | Should -Be 'TestWithoutNotifications'
            $script:store.AutoLabeling[0].ApplySensitivityLabel | Should -Be $script:store.SensitivityLabels[0].Identity
            $script:store.AutoLabelingRule[0].Policy | Should -Be $script:store.AutoLabeling[0].Identity
        }

        It 'records partial creation failures without claiming rollback or success' {
            $root = Join-Path $TestDrive 'service-failure'
            $path = New-TestExport $root
            Mock Invoke-PmCommand { throw 'Synthetic service failure' } -ParameterFilter { $Name -eq 'New-AutoSensitivityLabelPolicy' }
            { Import-PurviewMigrationPackage -Path $root -MappingsPath $path `
                -DestinationTenantId $script:destinationId -ConfirmDestinationTenantId $script:destinationId -VerificationDelaySeconds 0 -Confirm:$false } |
                Should -Throw '*Synthetic service failure*'
            $journal = Read-PmJson (Join-Path $root "import-$($script:destinationId).journal.json")
            $journal.Status | Should -Be 'Failed'
            $journal.Objects["AutoLabeling:$($script:policyId)"].State | Should -Be 'Creating'
            $script:store.SensitivityLabels.Count | Should -Be 1
            $script:store.ContainsKey('AutoLabelingRule') | Should -BeFalse
        }

        It 'bounds verification retries and leaves an explicit failure journal' {
            $root = Join-Path $TestDrive 'readback-failure'
            $path = New-TestExport $root
            $script:readAttempts = 0
            Mock Invoke-PmCommand {
                $script:readAttempts++
                $item = $script:store.SensitivityLabels[0].Clone()
                $item.Tooltip = 'unexpected change'
                [pscustomobject]$item
            } -ParameterFilter { $Name -eq 'Get-Label' -and $Parameters.Contains('Identity') }
            { Import-PurviewMigrationPackage -Path $root -MappingsPath $path `
                -DestinationTenantId $script:destinationId -ConfirmDestinationTenantId $script:destinationId `
                -VerificationAttempts 2 -VerificationDelaySeconds 0 -Confirm:$false } | Should -Throw '*verification failed*'
            $script:readAttempts | Should -Be 2
            (Read-PmJson (Join-Path $root "import-$($script:destinationId).journal.json")).Status | Should -Be 'Failed'
        }

        It 'rechecks earlier objects after later creations before marking success' {
            $root = Join-Path $TestDrive 'final-recheck'
            $path = New-TestExport $root
            Mock Invoke-PmCommand {
                $item = @{}
                foreach ($key in $Parameters.Keys) { $item[$key] = $Parameters[$key] }
                $item.Identity = [guid]::NewGuid().ToString()
                $item.Guid = $item.Identity
                $script:store.AutoLabeling = @($item)
                $script:store.SensitivityLabels[0].Tooltip = 'Changed after first verification'
                [pscustomobject]$item
            } -ParameterFilter { $Name -eq 'New-AutoSensitivityLabelPolicy' }
            { Import-PurviewMigrationPackage -Path $root -MappingsPath $path `
                -DestinationTenantId $script:destinationId -ConfirmDestinationTenantId $script:destinationId `
                -VerificationAttempts 1 -VerificationDelaySeconds 0 -Confirm:$false } | Should -Throw '*Tooltip*'
            (Read-PmJson (Join-Path $root "import-$($script:destinationId).journal.json")).Status | Should -Be 'Failed'
        }

        It 'resumes verified imports without duplicating creations' {
            $root = Join-Path $TestDrive 'resume'
            $path = New-TestExport $root
            $params = @{ Path = $root; MappingsPath = $path; DestinationTenantId = $script:destinationId; ConfirmDestinationTenantId = $script:destinationId; VerificationDelaySeconds = 0; Confirm = $false }
            $null = Import-PurviewMigrationPackage @params
            $creations = $script:store.Values | ForEach-Object { $_.Count } | Measure-Object -Sum
            $null = Import-PurviewMigrationPackage @params
            ($script:store.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum | Should -Be $creations.Sum
        }

        It 'blocks unsafe resume after an ambiguous interrupted create' {
            $root = Join-Path $TestDrive 'ambiguous'
            $path = New-TestExport $root
            $package = Read-PmPackage $root
            $mapping = Read-PmMappings $package $path
            $journalPath = Join-Path $root "import-$($script:destinationId).journal.json"
            $journal = Read-PmJournal $package $mapping $journalPath
            $journal.Objects[$package.Objects[0].Key] = @{ State = 'Creating'; DestinationId = ''; Name = 'uncertain' }
            Write-PmJson $journalPath $journal
            $plan = New-PurviewMigrationPlan -Path $root -MappingsPath $path
            $plan.CanImport | Should -BeFalse
            $plan.BlockingErrors -join ' ' | Should -Match 'interrupted during creation'
        }

        It 'invalidates resume after mapping changes' {
            $root = Join-Path $TestDrive 'changed-mapping'
            $path = New-TestExport $root
            $null = Import-PurviewMigrationPackage -Path $root -MappingsPath $path `
                -DestinationTenantId $script:destinationId -ConfirmDestinationTenantId $script:destinationId -VerificationDelaySeconds 0 -Confirm:$false
            $mapping = Read-PmJson $path
            @($mapping.Objects.Values)[0].Name = 'changed'
            Write-PmJson $path $mapping
            { New-PurviewMigrationPlan -Path $root -MappingsPath $path } | Should -Throw '*Mappings changed*'
        }

        It 'defers publication and only publishes when explicitly requested' {
            $root = Join-Path $TestDrive 'publishing'
            $path = New-TestExport $root @{ LabelPublishing = @('*') }
            $params = @{ Path = $root; MappingsPath = $path; DestinationTenantId = $script:destinationId; ConfirmDestinationTenantId = $script:destinationId; VerificationDelaySeconds = 0; Confirm = $false }
            $result = Import-PurviewMigrationPackage @params
            $result.Status | Should -Be 'VerifiedWithDeferredPublication'
            $script:store.ContainsKey('LabelPublishing') | Should -BeFalse
            $result = Import-PurviewMigrationPackage @params -PublishLabels
            $result.Status | Should -Be 'Verified'
            $script:store.LabelPublishing.Count | Should -Be 1
        }

        It 'does not invent a Set-LabelPolicy Priority parameter and flags manual order review' {
            $script:source.LabelPublishing[0].Priority = 4
            $root = Join-Path $TestDrive 'publishing-order'
            $path = New-TestExport $root @{ LabelPublishing = @('*') }
            $plan = New-PurviewMigrationPlan -Path $root -MappingsPath $path -PublishLabels
            @($plan.Steps | Where-Object Kind -eq 'LabelPublishing')[0].SetParameters.ContainsKey('Priority') | Should -BeFalse
            $result = Import-PurviewMigrationPackage -Path $root -MappingsPath $path `
                -DestinationTenantId $script:destinationId -ConfirmDestinationTenantId $script:destinationId `
                -VerificationDelaySeconds 0 -PublishLabels -Confirm:$false
            $result.Status | Should -Be 'ConfigurationVerifiedManualPublishingOrderRequired'
        }

        It 'supports an explicit label priority override in preview and verification' {
            $root = Join-Path $TestDrive 'label-priority'
            $path = New-TestExport $root @{ SensitivityLabels = @('*') }
            $mapping = Read-PmJson $path
            $mapping.Objects["SensitivityLabels:$($script:labelId)"].Priority = 9
            Write-PmJson $path $mapping
            $result = Import-PurviewMigrationPackage -Path $root -MappingsPath $path `
                -DestinationTenantId $script:destinationId -ConfirmDestinationTenantId $script:destinationId `
                -VerificationDelaySeconds 0 -Confirm:$false
            $result.Status | Should -Be 'Verified'
            $script:store.SensitivityLabels[0].Priority | Should -Be 9
        }

        It 'creates DLP disabled and maps nested JSON label references exactly' {
            $root = Join-Path $TestDrive 'dlp-import'
            $path = New-TestExport $root @{ Dlp = @('*') }
            $result = Import-PurviewMigrationPackage -Path $root -MappingsPath $path `
                -DestinationTenantId $script:destinationId -ConfirmDestinationTenantId $script:destinationId -VerificationDelaySeconds 0 -Confirm:$false
            $result.Status | Should -Be 'Verified'
            $script:store.Dlp[0].Mode | Should -Be 'Disable'
            $script:store.DlpRule[0].AdvancedRule | Should -Match $script:store.SensitivityLabels[0].Identity
            $script:store.DlpRule[0].AdvancedRule | Should -Not -Match $script:labelId
        }

        It 'never uses substring domain replacements' {
            $value = ConvertTo-PmMappedValue 'prefix-source.example.invalid-suffix' @{ 'source.example.invalid' = 'destination.example.invalid' }
            $value | Should -Be 'prefix-source.example.invalid-suffix'
        }

        It 'does not rewrite content-match literals or classifier group names as label references' {
            $rule = @{
                Condition = @{
                    Operator = 'And'
                    SubConditions = @(
                        @{ ConditionName = 'DocumentContainsWords'; Value = @('Confidential') },
                        @{ ConditionName = 'ContentContainsSensitiveInformation'; Value = @(@{
                            groups = @(@{ name = 'Confidential'; labels = @(@{ name = 'Confidential'; type = 'Sensitivity' }) })
                        }) }
                    )
                }
            }
            $mapped = ConvertTo-PmRuleValue $rule @{ Confidential = 'destination-label-guid' }
            $mapped.Condition.SubConditions[0].Value[0] | Should -Be 'Confidential'
            $mapped.Condition.SubConditions[1].Value[0].groups[0].name | Should -Be 'Confidential'
            $mapped.Condition.SubConditions[1].Value[0].groups[0].labels[0].name | Should -Be 'destination-label-guid'
        }

        It 'preserves JSON-looking literal marking text and label display names' {
            $definition = Get-PmDefinition 'SensitivityLabels' @{
                Name = 'Confidential'; Identity = $script:labelId; DisplayName = 'Confidential'
                Tooltip = '[IMPORTANT]'; LabelActions = @('{"Type":"mark","Text":"Confidential","Footer":"[IMPORTANT]"}')
            }
            $parameters = Get-PmCreateParameters $definition @{ Name = 'Confidential'; DisplayName = $null } @{ Confidential = 'destination-guid' } @{}
            $parameters.DisplayName | Should -Be 'Confidential'
            $parameters.LabelActions[0] | Should -Match '"Confidential"'
            $parameters.LabelActions[0] | Should -Match '\[IMPORTANT\]'
        }

        It 'normalizes JSON formatting without changing array order' {
            (Get-PmCanonicalJson '{"b":2,"a":1}') | Should -Be (Get-PmCanonicalJson '{ "a": 1, "b": 2 }')
            (Get-PmCanonicalJson @(1, 2)) | Should -Not -Be (Get-PmCanonicalJson @(2, 1))
        }

        It 'detects dependency cycles' {
            { Get-PmOrderedObjects @(@{ Key = 'a'; Dependencies = @('b') }, @{ Key = 'b'; Dependencies = @('a') }) } | Should -Throw '*Circular*'
        }

        It 'safely parses ordinary XML and rejects DTDs' {
            (Read-PmRuleXml $script:xml).DocumentElement.LocalName | Should -Be 'RulePackage'
            { Read-PmRuleXml '<!DOCTYPE RulePackage [<!ENTITY x SYSTEM "file:///C:/sensitive">]><RulePackage>&x;</RulePackage>' } | Should -Throw
        }

        It 'clones a SIT package ID without altering entity IDs or source XML' {
            $raw = [pscustomobject]@{ Name = 'Microsoft.SCCManaged.CustomRulePack'; SerializedClassificationRuleCollection = [Text.Encoding]::UTF8.GetBytes($script:xml) }
            $definition = Get-PmSitDefinition $raw
            $mapping = @{ DestinationId = '99999999-9999-9999-9999-999999999999'; Name = 'Migrated test' }
            $prepared = New-PmDestinationXml $definition $script:xml $mapping
            $prepared | Should -Match $mapping.DestinationId
            $prepared | Should -Match '88888888-8888-8888-8888-888888888888'
            $prepared | Should -Match 'Migrated test'
            $script:xml | Should -Not -Match 'Migrated test'
        }

        It 'identifies external SIT resources instead of assuming they are embedded' {
            $externalXml = $script:xml.Replace('idRef="TestRegex"', 'idRef="ExternalDictionary"')
            $raw = [pscustomobject]@{ Name = 'Test'; SerializedClassificationRuleCollection = [Text.Encoding]::UTF8.GetBytes($externalXml) }
            (Get-PmSitDefinition $raw).ExternalReferences | Should -Contain 'ExternalDictionary'
        }

        It 'preserves source XML bytes and emits a correct UTF8 destination declaration' {
            $xml = '<?xml version="1.0" encoding="utf-16"?>' + $script:xml
            $sourceBytes = [byte[]](@([Text.Encoding]::Unicode.GetPreamble()) + @([Text.Encoding]::Unicode.GetBytes($xml)))
            $definition = Get-PmSitDefinition ([pscustomobject]@{
                Name = 'Unicode test'; SerializedClassificationRuleCollection = $sourceBytes
            })
            [Convert]::ToHexString($definition.XmlBytes) | Should -Be ([Convert]::ToHexString($sourceBytes))
            $prepared = New-PmDestinationXml $definition $definition.XmlContent @{
                Name = 'Migrated Unicode test'; DestinationId = '99999999-9999-9999-9999-999999999999'
            }
            $prepared | Should -Match 'encoding="utf-8"'
            $prepared | Should -Not -Match 'encoding="utf-16"'
        }

        It 'parses <EncodingName> XML with BOM=<Bom> and declaration=<Declaration> without changing source bytes' -ForEach @(
            foreach ($encodingName in @('utf-8', 'utf-16', 'utf-16BE')) {
                foreach ($bom in @($false, $true)) {
                    foreach ($declaration in @($false, $true)) {
                        @{ EncodingName = $encodingName; Bom = $bom; Declaration = $declaration }
                    }
                }
            }
        ) {
            $encoding = [Text.Encoding]::GetEncoding($EncodingName)
            $xml = $script:xml.Replace('Test package', ('Test ' + [char]0x00e9 + ' package'))
            if ($Declaration) { $xml = '<?xml version="1.0" encoding="' + $EncodingName + '"?>' + $xml }
            $bytes = $encoding.GetBytes($xml)
            if ($Bom) { $bytes = [byte[]](@($encoding.GetPreamble()) + @($bytes)) }
            $definition = Get-PmSitDefinition ([pscustomobject]@{
                Name = $null; Identity = $null; SerializedClassificationRuleCollection = $bytes
            })
            $definition.SourceId | Should -Be '66666666-6666-6666-6666-666666666666'
            $definition.Name | Should -Be ('Test ' + [char]0x00e9 + ' package')
            [Convert]::ToHexString($definition.XmlBytes) | Should -Be ([Convert]::ToHexString($bytes))
        }

        It 'rejects malformed or unsafe XML byte streams rather than repairing or skipping them' {
            $unsafeXml = '<!DOCTYPE RulePackage [<!ENTITY x SYSTEM "file:///C:/sensitive">]><RulePackage>&x;</RulePackage>'
            { Read-PmRuleXml -Bytes ([Text.Encoding]::Unicode.GetBytes($unsafeXml)) } | Should -Throw
            { Read-PmRuleXml -Bytes ([byte[]]@(60, 0, 0, 0, 0)) } | Should -Throw
        }

        It 'exports, validates, imports and resumes a separate BOM-less <EncodingName> SIT package' -ForEach @(
            @{ EncodingName = 'utf-16' }
            @{ EncodingName = 'utf-16BE' }
        ) {
            $encoding = [Text.Encoding]::GetEncoding($EncodingName)
            $xml = '<?xml version="1.0" encoding="' + $EncodingName + '"?>' + $script:xml
            $bytes = $encoding.GetBytes($xml)
            $script:source.SensitiveInformationTypes = @([pscustomobject]@{
                Name = $null; Identity = $null; RuleCollectionName = 'Custom classification package'
                SerializedClassificationRuleCollection = $bytes
            })
            $root = Join-Path $TestDrive ('sit-encoding-' + $EncodingName)
            $path = New-TestExport $root @{ SensitiveInformationTypes = @('*') }
            $package = Read-PmPackage $root
            $sit = @($package.Objects | Where-Object Kind -eq 'SensitiveInformationTypes')
            $sit.Count | Should -Be 1
            @($package.Objects | Where-Object Kind -eq 'Dlp').Count | Should -Be 0
            (Get-Content -LiteralPath (Join-Path $root 'NEXT-STEPS.txt') -Raw) | Should -Not -Match 'For DLP custom classifier references'
            [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $root $sit[0].XmlFile))) |
                Should -Be ([Convert]::ToHexString($bytes))
            $script:writes | Should -Be 0
            $result = Import-PurviewMigrationPackage -Path $root -MappingsPath $path `
                -DestinationTenantId $script:destinationId -ConfirmDestinationTenantId $script:destinationId -VerificationDelaySeconds 0 -Confirm:$false
            $result.Status | Should -Be 'Verified'
            @(Test-PurviewMigrationImport -Path $root -MappingsPath $path | Where-Object Status -ne 'Verified').Count | Should -Be 0
            $writes = $script:writes
            $result = Import-PurviewMigrationPackage -Path $root -MappingsPath $path `
                -DestinationTenantId $script:destinationId -ConfirmDestinationTenantId $script:destinationId -VerificationDelaySeconds 0 -Confirm:$false
            $result.Status | Should -Be 'Verified'
            $script:writes | Should -Be $writes
            $script:store.SensitiveInformationTypes.Count | Should -Be 1
        }

        It 'exports, clones, imports and verifies a conventional SIT package' {
            $script:source.SensitiveInformationTypes = @(@{
                Name = 'Microsoft.SCCManaged.CustomRulePack'
                Identity = '66666666-6666-6666-6666-666666666666'
                SerializedClassificationRuleCollection = [Text.Encoding]::UTF8.GetBytes($script:xml)
            })
            $root = Join-Path $TestDrive 'sit-import'
            $path = New-TestExport $root @{ SensitiveInformationTypes = @('*') }
            $result = Import-PurviewMigrationPackage -Path $root -MappingsPath $path `
                -DestinationTenantId $script:destinationId -ConfirmDestinationTenantId $script:destinationId -VerificationDelaySeconds 0 -Confirm:$false
            $result.Status | Should -Be 'Verified'
            $script:store.SensitiveInformationTypes.Count | Should -Be 1
            $script:store.SensitiveInformationTypes[0].Identity | Should -Not -Be '66666666-6666-6666-6666-666666666666'
            (Get-PmSitDefinition ([pscustomobject]$script:store.SensitiveInformationTypes[0])).EntityIds |
                Should -Contain '88888888-8888-8888-8888-888888888888'
            @(Test-PurviewMigrationImport -Path $root -MappingsPath $path | Where-Object Status -ne 'Verified').Count | Should -Be 0
        }

        It 'exports DLP with the reported SIT response shape and skips the built-in package by RuleCollectionName' {
            $script:source.SensitiveInformationTypes = @(
                [pscustomobject]@{
                    Name = $null; Identity = $null; RuleCollectionName = 'Microsoft Rule Package'
                    LocalizedName = 'Microsoft Rule Package'; SerializedClassificationRuleCollection = $null
                },
                [pscustomobject]@{
                    Name = $null; Identity = [pscustomobject]@{}; RuleCollectionName = 'Custom classification package'
                    LocalizedName = 'Custom classifier'; SerializedClassificationRuleCollection = [Text.Encoding]::UTF8.GetBytes($script:xml)
                }
            )
            $script:source.DlpRule[0].AdvancedRule = $script:source.DlpRule[0].AdvancedRule.Replace(
                $script:labelId, '88888888-8888-8888-8888-888888888888')
            $root = Join-Path $TestDrive 'reported-sit-response'
            $null = Export-PurviewMigrationPackage -SourceTenantId $script:sourceId `
                -Selection @{ Dlp = @('*'); SensitiveInformationTypes = @('*') } -Path $root
            $package = Read-PmPackage $root
            $sit = @($package.Objects | Where-Object Kind -eq 'SensitiveInformationTypes')
            $sit.Count | Should -Be 1
            $sit[0].SourceId | Should -Be '66666666-6666-6666-6666-666666666666'
            $sit[0].Name | Should -Be 'Custom classification package'
            [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $root $sit[0].XmlFile))) |
                Should -Be ([Convert]::ToHexString([Text.Encoding]::UTF8.GetBytes($script:xml)))
            $script:writes | Should -Be 0
        }

        It 'excludes an unrelated unsupported SIT package from a selected DLP export' {
            $unsupportedXml = @'
<RulePackage xmlns="http://schemas.microsoft.com/office/2011/mce">
  <RulePack id="99999999-9999-9999-9999-999999999999">
    <Version major="1" minor="0" build="0" revision="0" />
    <Publisher id="77777777-7777-7777-7777-777777777777" />
    <Details defaultLangCode="en-us"><LocalizedDetails langcode="en-us"><Name>Unsupported fixture</Name></LocalizedDetails></Details>
  </RulePack>
  <Rules><Regex id="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa">sample</Regex></Rules>
</RulePackage>
'@
            $script:source.SensitiveInformationTypes = @(
                [pscustomobject]@{
                    Name = $null; Identity = $null; RuleCollectionName = 'Unrelated unsupported package'
                    LocalizedName = 'Unrelated unsupported package'
                    SerializedClassificationRuleCollection = [Text.Encoding]::UTF8.GetBytes($unsupportedXml)
                    IsAIPoweredRuleCollection = $false; IsFingerprintRuleCollection = $false
                },
                [pscustomobject]@{
                    Name = 'Supported fixture'; Identity = '66666666-6666-6666-6666-666666666666'
                    SerializedClassificationRuleCollection = [Text.Encoding]::UTF8.GetBytes($script:xml)
                }
            )
            $root = Join-Path $TestDrive 'unrelated-unsupported-sit'
            $null = Export-PurviewMigrationPackage -SourceTenantId $script:sourceId `
                -Selection @{ Dlp = @('*'); SensitiveInformationTypes = @('66666666-6666-6666-6666-666666666666') } -Path $root
            $package = Read-PmPackage $root
            @($package.Objects | Where-Object Kind -eq 'SensitiveInformationTypes').Count | Should -Be 1
            @($package.Objects | Where-Object SourceId -eq '99999999-9999-9999-9999-999999999999').Count | Should -Be 0
            @($package.Objects | Where-Object SourceId -eq '66666666-6666-6666-6666-666666666666').Count | Should -Be 1
            @($package.Objects | Where-Object Kind -eq 'Dlp').Count | Should -Be 1
            @($package.Objects | Where-Object Kind -eq 'DlpRule').Count | Should -Be 1
            (Test-PurviewMigrationPackage $root).Valid | Should -BeTrue
            Should -Invoke Invoke-PmCommand -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'Get-DlpSensitiveInformationTypeRulePackage'
            }
            $script:writes | Should -Be 0
        }

        It 'blocks an explicitly selected unsupported SIT package with a safe structural summary' {
            $unsupportedXml = @'
<RulePackage xmlns="http://schemas.microsoft.com/office/2011/mce">
  <RulePack id="99999999-9999-9999-9999-999999999999">
    <Details defaultLangCode="en-us"><LocalizedDetails langcode="en-us"><Name>Unsupported fixture</Name></LocalizedDetails></Details>
  </RulePack>
  <Rules><Regex id="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa">sensitive fixture text</Regex></Rules>
</RulePackage>
'@
            $script:source.SensitiveInformationTypes = @([pscustomobject]@{
                Name = $null; Identity = $null; RuleCollectionName = 'Unsupported fixture'
                SerializedClassificationRuleCollection = [Text.Encoding]::UTF8.GetBytes($unsupportedXml)
                IsAIPoweredRuleCollection = $false; IsFingerprintRuleCollection = $false
            })
            $catalog = Get-PmCatalog @('SensitiveInformationTypes')
            $catalog.Count | Should -Be 1
            $catalog[0].UnsupportedFields[0] | Should -Match '0 Entity elements; root=RulePackage; namespace=http://schemas.microsoft.com/office/2011/mce; Rules children=Regex=1'
            $catalog[0].UnsupportedFields[0] | Should -Not -Match 'sensitive fixture text'
            $root = Join-Path $TestDrive 'selected-unsupported-sit'
            { Export-PurviewMigrationPackage -SourceTenantId $script:sourceId `
                -Selection @{ SensitiveInformationTypes = @('99999999-9999-9999-9999-999999999999') } -Path $root } |
                Should -Throw '*unsupported populated fields*Unsupported SIT XML structure*Regex=1*'
            Test-Path -LiteralPath $root | Should -BeFalse
            $script:writes | Should -Be 0
        }

        It 'blocks a selected DLP policy that references an unselected unsupported SIT package' {
            $unsupportedXml = @'
<RulePackage xmlns="http://schemas.microsoft.com/office/2011/mce">
  <RulePack id="99999999-9999-9999-9999-999999999999">
    <Details defaultLangCode="en-us"><LocalizedDetails langcode="en-us"><Name>Unsupported fixture</Name></LocalizedDetails></Details>
  </RulePack>
  <Rules><Classifier id="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" /></Rules>
</RulePackage>
'@
            $script:source.SensitiveInformationTypes = @(
                [pscustomobject]@{
                    Name = $null; Identity = $null; RuleCollectionName = 'Unsupported fixture'
                    SerializedClassificationRuleCollection = [Text.Encoding]::UTF8.GetBytes($unsupportedXml)
                },
                [pscustomobject]@{
                    Name = 'Selected supported fixture'; Identity = '66666666-6666-6666-6666-666666666666'
                    SerializedClassificationRuleCollection = [Text.Encoding]::UTF8.GetBytes($script:xml)
                }
            )
            $script:source.DlpRule[0].AdvancedRule =
                '{"Condition":{"SensitiveInformationTypeId":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}}'
            $root = Join-Path $TestDrive 'referenced-unsupported-sit'
            { Export-PurviewMigrationPackage -SourceTenantId $script:sourceId `
                -Selection @{ Dlp = @('*'); SensitiveInformationTypes = @('66666666-6666-6666-6666-666666666666') } -Path $root } |
                Should -Throw '*SensitiveInformationTypes*unsupported populated fields*Unsupported SIT XML structure*'
            Test-Path -LiteralPath $root | Should -BeFalse
            $script:writes | Should -Be 0
        }

        It 'does not enumerate malformed SIT packages during a DLP-only export' {
            $script:source.SensitiveInformationTypes = @([pscustomobject]@{
                Name = $null; Identity = $null; RuleCollectionName = 'Malformed package'
                SerializedClassificationRuleCollection = [Text.Encoding]::UTF8.GetBytes('<RulePackage><broken>')
            })
            $root = Join-Path $TestDrive 'malformed-sit-dependency'
            $null = Export-PurviewMigrationPackage -SourceTenantId $script:sourceId `
                -Selection @{ Dlp = @('*') } -Path $root
            @((Read-PmPackage $root).Objects | Where-Object Kind -eq 'SensitiveInformationTypes').Count | Should -Be 0
            Should -Invoke Invoke-PmCommand -Times 0 -Exactly -ParameterFilter {
                $Name -eq 'Get-DlpSensitiveInformationTypeRulePackage'
            }
            $script:writes | Should -Be 0
        }

        It 'keeps DLP custom classifier identifiers as explicit external mappings when SIT export is omitted' {
            $classifierId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            $script:source.DlpRule[0].AdvancedRule =
                '{"Condition":{"ConditionName":"ContentContainsSensitiveInformation","Value":[{"groups":[{"name":"Default","labels":[{"name":"' + $classifierId + '","type":"Custom"}]}]}]}}'
            $root = Join-Path $TestDrive 'dlp-without-sit-package'
            $null = Export-PurviewMigrationPackage -SourceTenantId $script:sourceId `
                -Selection @{ Dlp = @('*') } -Path $root
            $package = Read-PmPackage $root
            @($package.Objects | Where-Object Kind -eq 'SensitiveInformationTypes').Count | Should -Be 0
            $mappings = Read-PmJson (Join-Path $root 'mappings.json')
            $mappings.References.ContainsKey($classifierId) | Should -BeTrue
            $mappings.References[$classifierId].Reviewed | Should -BeFalse
            (Get-Content -LiteralPath (Join-Path $root 'NEXT-STEPS.txt') -Raw) | Should -Match 'For DLP custom classifier references'
        }

        It 'imports DLP against an already-migrated SIT using an explicitly mapped classifier ID' {
            $sourceClassifierId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            $destinationClassifierId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
            $script:source.DlpRule[0].AdvancedRule =
                '{"Condition":{"ConditionName":"ContentContainsSensitiveInformation","Value":[{"groups":[{"name":"Default","labels":[{"name":"' + $sourceClassifierId + '","type":"Custom"}]}]}]}}'
            $root = Join-Path $TestDrive 'dlp-existing-sit'
            $path = New-TestExport $root @{ Dlp = @('*') }
            $mappings = Read-PmJson $path
            $mappings.References[$sourceClassifierId].Value = $destinationClassifierId
            $mappings.References[$sourceClassifierId].Reviewed = $true
            $mappings.References[$sourceClassifierId].Evidence = 'Existing destination SIT entity ID independently verified'
            Write-PmJson $path $mappings
            $result = Import-PurviewMigrationPackage -Path $root -MappingsPath $path `
                -DestinationTenantId $script:destinationId -ConfirmDestinationTenantId $script:destinationId `
                -VerificationDelaySeconds 0 -Confirm:$false
            $result.Status | Should -Be 'Verified'
            $script:store.DlpRule[0].AdvancedRule | Should -Match $destinationClassifierId
            $script:store.DlpRule[0].AdvancedRule | Should -Not -Match $sourceClassifierId
            @($script:store['SensitiveInformationTypes'] | Where-Object { $null -ne $_ }).Count | Should -Be 0
        }

        It 'retrieves a summary-only SIT package by its documented RuleCollectionName' {
            Mock Invoke-PmCommand {
                if ($Parameters.Contains('Identity')) {
                    [pscustomobject]@{
                        Name = $null; Identity = $null; RuleCollectionName = 'Custom classification package'
                        LocalizedName = 'Localized package'; SerializedClassificationRuleCollection = [Text.Encoding]::UTF8.GetBytes($script:xml)
                    }
                } else {
                    [pscustomobject]@{
                        Name = $null; Identity = $null; RuleCollectionName = 'Custom classification package'
                        LocalizedName = 'Localized package'; SerializedClassificationRuleCollection = $null
                    }
                }
            } -ParameterFilter { $Name -eq 'Get-DlpSensitiveInformationTypeRulePackage' }
            $catalog = Get-PmCatalog @('SensitiveInformationTypes')
            $catalog[0].SourceId | Should -Be '66666666-6666-6666-6666-666666666666'
            Should -Invoke Invoke-PmCommand -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'Get-DlpSensitiveInformationTypeRulePackage' -and $Parameters.Identity -eq 'Custom classification package'
            }
        }

        It 'uses XML package identity and name when generic SIT metadata fields are empty' {
            $raw = [pscustomobject]@{
                Name = $null; Identity = $null; RuleCollectionName = $null; LocalizedName = $null
                ClassificationRuleCollectionXml = $script:xml
                SerializedClassificationRuleCollection = [Text.Encoding]::UTF8.GetBytes($script:xml)
            }
            $wire = [Management.Automation.PSSerializer]::Deserialize([Management.Automation.PSSerializer]::Serialize($raw))
            $definition = Get-PmSitDefinition $wire
            $definition.Name | Should -Be 'Test package'
            $definition.SourceId | Should -Be '66666666-6666-6666-6666-666666666666'
            (Get-PmSitReadIdentity (ConvertTo-PmData $wire)) | Should -Be $definition.SourceId
        }

        It 'retrieves a summary-only SIT using its XML GUID when all metadata locators are empty' {
            Mock Invoke-PmCommand {
                if ($Parameters.Contains('Identity')) {
                    [pscustomobject]@{ Name = $null; Identity = $null; SerializedClassificationRuleCollection = [Text.Encoding]::UTF8.GetBytes($script:xml) }
                } else {
                    [pscustomobject]@{ Name = $null; Identity = $null; ClassificationRuleCollectionXml = $script:xml }
                }
            } -ParameterFilter { $Name -eq 'Get-DlpSensitiveInformationTypeRulePackage' }
            $catalog = Get-PmCatalog @('SensitiveInformationTypes')
            $catalog[0].Name | Should -Be 'Test package'
            Should -Invoke Invoke-PmCommand -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'Get-DlpSensitiveInformationTypeRulePackage' -and $Parameters.Identity -eq '66666666-6666-6666-6666-666666666666'
            }
        }

        It 'uses the default-language XML package name rather than the first localized name' {
            $xml = $script:xml.Replace('<LocalizedDetails langcode="en-us">', '<LocalizedDetails langcode="fr-fr"><Name>French name</Name></LocalizedDetails><LocalizedDetails langcode="en-us">')
            $definition = Get-PmSitDefinition ([pscustomobject]@{
                Name = $null; Identity = $null; SerializedClassificationRuleCollection = [Text.Encoding]::UTF8.GetBytes($xml)
            })
            $definition.Name | Should -Be 'Test package'
            $definition.Aliases | Should -Contain 'French name'
        }

        It 'blocks empty XML package GUIDs before using them as retrieval locators' {
            $xml = $script:xml.Replace('66666666-6666-6666-6666-666666666666', [guid]::Empty.ToString())
            { Get-PmSitReadIdentity @{ ClassificationRuleCollectionXml = $xml } } | Should -Throw '*nonempty GUID*'
            { Get-PmSitDefinition ([pscustomobject]@{
                Name = 'Invalid'; SerializedClassificationRuleCollection = [Text.Encoding]::UTF8.GetBytes($xml)
            }) } | Should -Throw '*nonempty GUID*'
        }
        It 'blocks a summary-only SIT response that cannot be safely located' {
            Mock Invoke-PmCommand { [pscustomobject]@{
                Name = $null; Identity = $null; RuleCollectionName = $null
                LocalizedName = $null; SerializedClassificationRuleCollection = $null
            } } -ParameterFilter { $Name -eq 'Get-DlpSensitiveInformationTypeRulePackage' }
            { Get-PmCatalog @('SensitiveInformationTypes') } | Should -Throw '*SIT summary has no usable identity*'
            $script:writes | Should -Be 0
        }

        It 'rejects a SIT detail result that does not match the requested summary package' {
            Mock Invoke-PmCommand {
                if ($Parameters.Contains('Identity')) {
                    [pscustomobject]@{ Name = 'Different package'; SerializedClassificationRuleCollection = [Text.Encoding]::UTF8.GetBytes($script:xml) }
                } else {
                    [pscustomobject]@{ Name = $null; Identity = $null; RuleCollectionName = 'Requested package' }
                }
            } -ParameterFilter { $Name -eq 'Get-DlpSensitiveInformationTypeRulePackage' }
            { Get-PmCatalog @('SensitiveInformationTypes') } | Should -Throw '*does not match requested package*'
        }

        It 'imports, verifies and reuses SITs when destination responses have no generic Name or Identity' {
            $script:source.SensitiveInformationTypes = @(@{
                Name = 'Test package'; Identity = '66666666-6666-6666-6666-666666666666'
                SerializedClassificationRuleCollection = [Text.Encoding]::UTF8.GetBytes($script:xml)
            })
            $root = Join-Path $TestDrive 'sit-destination-shape'
            $path = New-TestExport $root @{ SensitiveInformationTypes = @('*') }
            Mock Invoke-PmCommand {
                foreach ($item in @($script:store['SensitiveInformationTypes'] | Where-Object { $null -ne $_ })) {
                    [pscustomobject]@{
                        Name = $null; Identity = $null; RuleCollectionName = 'Service.InternalRulePack'
                        LocalizedName = $item.Name; SerializedClassificationRuleCollection = $item.SerializedClassificationRuleCollection
                    }
                }
            } -ParameterFilter { $Name -eq 'Get-DlpSensitiveInformationTypeRulePackage' -and $script:tenant -eq $script:destinationId }
            $result = Import-PurviewMigrationPackage -Path $root -MappingsPath $path -DestinationTenantId $script:destinationId `
                -ConfirmDestinationTenantId $script:destinationId -Confirm:$false -VerificationDelaySeconds 0
            $result.Status | Should -Be 'Verified'
            $script:writes | Should -Be 1
            $null = Import-PurviewMigrationPackage -Path $root -MappingsPath $path -DestinationTenantId $script:destinationId `
                -ConfirmDestinationTenantId $script:destinationId -Confirm:$false -VerificationDelaySeconds 0
            $script:writes | Should -Be 1
            $reuseRoot = Join-Path $TestDrive 'sit-destination-reuse'
            $reusePath = New-TestExport $reuseRoot @{ SensitiveInformationTypes = @('*') }
            $mapping = Read-PmJson $reusePath
            $entry = @($mapping.Objects.Values)[0]
            $entry.Action = 'Reuse'
            $entry.DestinationId = $script:store.SensitiveInformationTypes[0].Identity
            Write-PmJson $reusePath $mapping
            $result = Import-PurviewMigrationPackage -Path $reuseRoot -MappingsPath $reusePath -DestinationTenantId $script:destinationId `
                -ConfirmDestinationTenantId $script:destinationId -Confirm:$false -VerificationDelaySeconds 0
            $result.Verification[0].Status | Should -Be 'ReusedExistsNotContentVerified'
            $script:writes | Should -Be 1
            $changedXml = [Text.Encoding]::UTF8.GetString($script:store.SensitiveInformationTypes[0].SerializedClassificationRuleCollection).Replace('EMP-', 'CHANGED-')
            $script:store.SensitiveInformationTypes[0].SerializedClassificationRuleCollection = [Text.Encoding]::UTF8.GetBytes($changedXml)
            { Import-PurviewMigrationPackage -Path $root -MappingsPath $path -DestinationTenantId $script:destinationId `
                -ConfirmDestinationTenantId $script:destinationId -Confirm:$false -VerificationDelaySeconds 0 } |
                Should -Throw '*SIT XML read-back differs*'
            $script:writes | Should -Be 1
        }

        It 'blocks destination SIT entity ID collisions without writing' {
            $script:source.SensitiveInformationTypes = @(@{
                Name = 'Test custom package'; Identity = '66666666-6666-6666-6666-666666666666'
                SerializedClassificationRuleCollection = [Text.Encoding]::UTF8.GetBytes($script:xml)
            })
            $root = Join-Path $TestDrive 'sit-collision'
            $path = New-TestExport $root @{ SensitiveInformationTypes = @('*') }
            $script:extraSitIds = @('88888888-8888-8888-8888-888888888888')
            $plan = New-PurviewMigrationPlan -Path $root -MappingsPath $path
            $plan.CanImport | Should -BeFalse
            $plan.BlockingErrors -join ' ' | Should -Match 'SIT entity ID'
            $script:writes | Should -Be 0
        }

        It 'maps localized SIT names to entity IDs, never the rule package ID' {
            $localizedXml = $script:xml.Replace('</Rules>', '<LocalizedStrings><Resource idRef="88888888-8888-8888-8888-888888888888"><Name default="true" langcode="en-us">Employee test</Name></Resource></LocalizedStrings></Rules>')
            $definition = Get-PmSitDefinition ([pscustomobject]@{
                Name = 'Test'; SerializedClassificationRuleCollection = [Text.Encoding]::UTF8.GetBytes($localizedXml)
            })
            $mappings = @{ Objects = @{}; References = @{} }
            $mappings.Objects[$definition.Key] = @{ Action = 'Create'; DestinationId = '99999999-9999-9999-9999-999999999999' }
            $replacements = Get-PmReplacements @{ Objects = @($definition) } $mappings @{}
            $replacements['Employee test'] | Should -Be '88888888-8888-8888-8888-888888888888'
        }
    }
}
