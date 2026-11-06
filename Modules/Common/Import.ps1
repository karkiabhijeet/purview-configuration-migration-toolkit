function Read-PmMappings {
    param($Package, [string]$Path)
    $mappings = Read-PmJson $Path
    if ($mappings.SchemaVersion -ne 1 -or $mappings.PackageId -ne $Package.Manifest.PackageId) {
        throw 'Mappings do not belong to this package/schema.'
    }
    $tenant = [guid]$mappings.DestinationTenantId
    if ($tenant -eq [guid]::Empty -or $tenant -eq [guid]$Package.Manifest.SourceTenantId) {
        throw 'DestinationTenantId must identify a different, nonempty tenant.'
    }
    foreach ($definition in $Package.Objects) {
        if (-not $mappings.Objects.ContainsKey($definition.Key)) { throw "Missing mapping for '$($definition.Key)'." }
    }
    return $mappings
}

function Get-PmOrderedObjects {
    param([array]$Definitions)
    $ordered = [Collections.Generic.List[object]]::new()
    $remaining = @($Definitions)
    $done = @{}
    while ($remaining.Count) {
        $ready = @($remaining | Where-Object {
            $unresolved = @($_.Dependencies | Where-Object { -not $done.ContainsKey($_) })
            $unresolved.Count -eq 0
        } | Sort-Object Kind, @{ Expression = { if ($_.Fields.ContainsKey('Priority')) { [int]$_.Fields.Priority } else { [int]::MaxValue } } }, Name | Select-Object -First 1)
        if (-not $ready.Count) { throw 'Circular or missing dependencies in migration package.' }
        foreach ($definition in $ready) {
            $ordered.Add($definition)
            $done[$definition.Key] = $true
        }
        $remaining = @($remaining | Where-Object { -not $done.ContainsKey($_.Key) })
    }
    return ,@($ordered)
}

function ConvertTo-PmMappedValue {
    param([AllowNull()]$Value, [hashtable]$Replacements)
    if ($Value -is [string]) {
        if ($Replacements.ContainsKey($Value)) { return $Replacements[$Value] }
        $parsed = ConvertFrom-PmJsonField $Value
        if ($parsed -isnot [string]) {
            return ConvertTo-Json -InputObject (ConvertTo-PmMappedValue $parsed $Replacements) -Depth 100 -Compress
        }
        return $Value
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $Value.Keys) { $result[$key] = ConvertTo-PmMappedValue $Value[$key] $Replacements }
        return $result
    }
    if ($Value -is [array]) { return ,@($Value | ForEach-Object { ConvertTo-PmMappedValue $_ $Replacements }) }
    return $Value
}

function Get-PmReplacements {
    param($Package, $Mappings, [hashtable]$ResolvedIds, [switch]$Preview)
    $replacements = @{}
    foreach ($source in $Mappings.References.Keys) {
        $entry = $Mappings.References[$source]
        if ($entry.Reviewed -eq $true -and $entry.Value) { $replacements[$source] = [string]$entry.Value }
    }
    foreach ($definition in $Package.Objects) {
        if ($definition.Kind -notin @('SensitivityLabels', 'SensitiveInformationTypes')) { continue }
        $mapping = $Mappings.Objects[$definition.Key]
        $destinationId = if ($ResolvedIds.ContainsKey($definition.Key)) { $ResolvedIds[$definition.Key] }
            elseif ($mapping.Action -eq 'Reuse' -or $definition.Kind -eq 'SensitiveInformationTypes') { $mapping.DestinationId }
            elseif ($Preview) { "<created:$($definition.Key)>" }
            else { $null }
        if ($destinationId) {
            foreach ($alias in $definition.Aliases) {
                if ($definition.Kind -eq 'SensitiveInformationTypes' -and $definition.EntityAliases.ContainsKey($alias)) {
                    if ($replacements.ContainsKey($alias) -and $replacements[$alias] -ne $definition.EntityAliases[$alias]) {
                        throw "Entity-ID rewriting is not supported for '$alias'. Reuse requires compatible original entity IDs."
                    }
                    $replacements[$alias] = $definition.EntityAliases[$alias]
                } else {
                    if ($replacements.ContainsKey($alias) -and $replacements[$alias] -ne $destinationId) {
                        throw "Conflicting replacement for '$alias'. Use unique source object names/identities."
                    }
                    $replacements[$alias] = [string]$destinationId
                }
            }
        }
    }
    return $replacements
}

function Get-PmExternalMap {
    param($Mappings)
    $result = @{}
    foreach ($source in $Mappings.References.Keys) {
        $entry = $Mappings.References[$source]
        if ($entry.Reviewed -eq $true -and $entry.Value) { $result[$source] = [string]$entry.Value }
    }
    return $result
}

function ConvertTo-PmRuleValue {
    param([AllowNull()]$Value, [hashtable]$Replacements, [switch]$ClassifierContext)
    if ($Value -is [string]) {
        $parsed = ConvertFrom-PmJsonField $Value
        if ($parsed -is [string]) { return $Value }
        return ConvertTo-Json -InputObject (ConvertTo-PmRuleValue $parsed $Replacements -ClassifierContext:$ClassifierContext) -Depth 100 -Compress
    }
    if ($Value -is [array]) {
        return ,@($Value | ForEach-Object { ConvertTo-PmRuleValue $_ $Replacements -ClassifierContext:$ClassifierContext })
    }
    if ($Value -isnot [System.Collections.IDictionary]) { return $Value }
    $result = @{}
    $isGroup = @(@('groups', 'labels', 'Operator', 'SubConditions') | Where-Object { $Value.Contains($_) }).Count -gt 0
    foreach ($key in $Value.Keys) {
        $child = $Value[$key]
        if ($ClassifierContext -and -not $isGroup -and $key -in @('name', 'id', 'classifierid') -and $child -is [string] -and $Replacements.ContainsKey($child)) {
            $result[$key] = $Replacements[$child]
        } elseif ($key -eq 'Value' -and $Value.Contains('ConditionName')) {
            $condition = [string]$Value['ConditionName']
            if ($condition -in @('ContentContainsSensitiveInformation', 'ExceptIfContentContainsSensitiveInformation')) {
                $result[$key] = ConvertTo-PmRuleValue $child $Replacements -ClassifierContext
            } elseif ($condition -in @(
                'From', 'FromMemberOf', 'SentTo', 'SentToMemberOf', 'SenderDomainIs', 'RecipientDomainIs',
                'ExceptIfFrom', 'ExceptIfFromMemberOf', 'ExceptIfSentTo', 'ExceptIfSentToMemberOf',
                'ExceptIfSenderDomainIs', 'ExceptIfRecipientDomainIs', 'DocumentCreatedBy', 'DocumentCreatedByMemberOf'
            )) {
                $result[$key] = ConvertTo-PmMappedValue $child $Replacements
            } else { $result[$key] = $child }
        } else {
            $result[$key] = ConvertTo-PmRuleValue $child $Replacements -ClassifierContext:$ClassifierContext
        }
    }
    return $result
}

function Get-PmCreateParameters {
    param($Definition, $Mapping, [hashtable]$Replacements, [hashtable]$ResolvedIds, [hashtable]$ExternalReplacements = @{})
    if ($Definition.ContainsKey('ExistingLabelReference') -and $Mapping.Action -eq 'Create') {
        throw "Label '$($Definition.Name)' is an existing-label identity reference only; Create is forbidden. Map it to an existing destination label."
    }
    $spec = $script:PmSpecifications[$Definition.Kind]
    $parameters = @{}
    foreach ($field in $Definition.Fields.Keys) {
        if ($field -in $spec.SetOnly) { continue }
        $parameters[$field] = if ($field -eq 'LabelActions') {
            ConvertTo-PmMappedValue $Definition.Fields[$field] $ExternalReplacements
        } elseif ($field -eq 'AdvancedRule') {
            ConvertTo-PmRuleValue $Definition.Fields[$field] $Replacements
        } elseif ($field -in @('ContentContainsSensitiveInformation', 'ExceptIfContentContainsSensitiveInformation', 'Conditions', 'SchematizedDataCondition')) {
            ConvertTo-PmRuleValue $Definition.Fields[$field] $Replacements -ClassifierContext
        } elseif ($field -in @($spec.References + $spec.External)) {
            ConvertTo-PmMappedValue $Definition.Fields[$field] $Replacements
        } else { $Definition.Fields[$field] }
    }
    $parameters.Name = [string]$Mapping.Name
    if ($parameters.ContainsKey('Priority')) { $parameters.Priority = Get-PmEffectivePriority $Definition $Mapping }
    if ($Definition.Kind -eq 'SensitivityLabels' -and $Mapping['DisplayName']) { $parameters.DisplayName = [string]$Mapping['DisplayName'] }
    if ($spec.ContainsKey('SafeMode')) { $parameters.Mode = $spec.SafeMode }
    if ($Definition.ParentKey) {
        if (-not $ResolvedIds.ContainsKey($Definition.ParentKey)) { throw "Parent policy '$($Definition.ParentKey)' has not been resolved." }
        $parameters.Policy = $ResolvedIds[$Definition.ParentKey]
    }
    return $parameters
}

function Get-PmEffectivePriority {
    param($Definition, $Mapping)
    if ($Mapping.ContainsKey('Priority') -and $null -ne $Mapping.Priority) {
        $priority = 0
        if (-not [int]::TryParse([string]$Mapping.Priority, [ref]$priority) -or $priority -lt 0) {
            throw "$($Definition.Key): Priority override must be a nonnegative integer."
        }
        return $priority
    }
    return $Definition.Fields['Priority']
}

function Get-PmSetParameters {
    param($Definition, $Mapping, [string]$Identity)
    $parameters = @{ Identity = $Identity }
    foreach ($field in $script:PmSpecifications[$Definition.Kind].SetOnly) {
        if ($Definition.Kind -eq 'LabelPublishing' -and $field -eq 'Priority') { continue }
        if ($Definition.Fields.ContainsKey($field)) {
            $parameters[$field] = if ($field -eq 'Priority') { Get-PmEffectivePriority $Definition $Mapping } else { $Definition.Fields[$field] }
        }
    }
    return $parameters
}

function Get-PmDestinationInventory {
    param([array]$Definitions)
    $inventory = @{}
    foreach ($kind in @($Definitions.Kind | Select-Object -Unique)) {
        if ($kind -eq 'SensitiveInformationTypes') {
            $inventory[$kind] = @(
                foreach ($definition in (Get-PmCatalog @('SensitiveInformationTypes'))) {
                    ConvertTo-PmSitRecord $definition
                }
            )
            continue
        }
        $spec = $script:PmSpecifications[$kind]
        $parameters = @{}
        if ($kind -eq 'SensitivityLabels') { $parameters.IncludeDetailedLabelActions = $true }
        $inventory[$kind] = @(Invoke-PmCommand $spec.Get $parameters | ForEach-Object { ConvertTo-PmData $_ })
    }
    return $inventory
}

function Find-PmExistingObject {
    param([array]$Inventory, [string]$Identity)
    @($Inventory | Where-Object {
        $Identity -in @(Get-PmIdentityValues $_)
    })
}

function Read-PmJournal {
    param($Package, $Mappings, [string]$Path)
    if (Test-Path -LiteralPath $Path) {
        $journal = Read-PmJson $Path
        if ($journal.PackageId -ne $Package.Manifest.PackageId -or $journal.DestinationTenantId -ne $Mappings.DestinationTenantId) {
            throw 'Journal belongs to a different package or destination.'
        }
        if ($journal.MappingsHash -ne (Get-PmCanonicalJson $Mappings | Get-PmTextHash)) {
            throw 'Mappings changed after import started. Use the original mappings and journal; do not silently resume with different instructions.'
        }
        return $journal
    }
    @{
        SchemaVersion = 1; PackageId = $Package.Manifest.PackageId
        DestinationTenantId = $Mappings.DestinationTenantId
        MappingsHash = (Get-PmCanonicalJson $Mappings | Get-PmTextHash)
        Objects = @{}; Status = 'Prepared'
    }
}

function Get-PmTextHash {
    param([Parameter(ValueFromPipeline)][string]$Text)
    process {
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text)))
    }
}

function New-PurviewMigrationPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$MappingsPath,
        [string]$JournalPath,
        [switch]$Offline,
        [switch]$PublishLabels,
        [ValidateRange(1, 100000)][int]$MaximumObjects = 10000
    )
    $package = Read-PmPackage $Path
    $mappings = Read-PmMappings $package $MappingsPath
    if (-not $JournalPath) { $JournalPath = Join-Path $package.Root "import-$($mappings.DestinationTenantId).journal.json" }
    if ([IO.Path]::GetFileName($JournalPath) -notmatch '\.journal\.json$') {
        throw 'JournalPath must end in .journal.json to avoid overwriting package or mapping files.'
    }
    $journal = Read-PmJournal $package $mappings $JournalPath
    $errors = [Collections.Generic.List[string]]::new()
    $warnings = [Collections.Generic.List[string]]::new()
    if ($package.Objects.Count -gt $MaximumObjects) { $errors.Add("Object count exceeds explicit safety limit $MaximumObjects.") }
    $destination = @{}
    $sitIds = @()
    if (-not $Offline) {
        $null = Get-PurviewMigrationSession -ExpectedTenantId $mappings.DestinationTenantId
        $destination = Get-PmDestinationInventory $package.Objects
        if (@($package.Objects | Where-Object { $_.Kind -eq 'SensitiveInformationTypes' }).Count) {
            $sitIds = @(Invoke-PmCommand 'Get-DlpSensitiveInformationType' @{} | ForEach-Object { [string]$_.Id })
        }
    }
    foreach ($definition in $package.Objects) {
        foreach ($reference in $definition.ExternalReferences) {
            if (-not $mappings.References.ContainsKey($reference)) {
                $errors.Add("$($definition.Key): missing external reference mapping '$reference'.")
                continue
            }
            $entry = $mappings.References[$reference]
            if ($entry.Reviewed -ne $true -or -not $entry.Value -or -not $entry.Evidence) {
                $errors.Add("$($definition.Key): reference '$reference' needs Value, Reviewed=true, and destination validation Evidence.")
            }
        }
    }
    $replacements = Get-PmReplacements $package $mappings @{} -Preview
    $steps = [Collections.Generic.List[object]]::new()
    $resolved = @{}
    $names = @{}
    foreach ($definition in (Get-PmOrderedObjects $package.Objects)) {
        $mapping = $mappings.Objects[$definition.Key]
        $action = [string]$mapping.Action
        if ($definition.Kind -eq 'DlpRule') {
            $warnings.Add("$($definition.Key): supported alert/incident-report settings are retained when populated; the source ProtectionAlertId response identifier is not copied. Compare destination Incident reports settings and test alert behavior before activation. Configuration read-back does not verify alert delivery or automatic identifier allocation.")
        }
        $status = if ($definition.Kind -eq 'LabelPublishing' -and -not $PublishLabels) { 'DeferredPublication' } else { 'Planned' }
        if ($action -notin @('Create', 'Reuse')) { $errors.Add("$($definition.Key): choose Action Create or Reuse instead of '$action'.") }
        if ($definition.ContainsKey('ExistingLabelReference')) {
            $warnings.Add("$($definition.Key): label configuration was NOT exported and will not be created or updated. Reuse verifies identity existence, not label content/protection equivalence; independently validate the destination label before activation.")
            if ($action -ne 'Reuse') {
                $errors.Add("$($definition.Key): identity-only label reference requires Action Reuse, never Create.")
            }
            $labelId = [guid]::Empty
            if (-not [guid]::TryParse([string]$mapping.DestinationId, [ref]$labelId) -or $labelId -eq [guid]::Empty) {
                $errors.Add("$($definition.Key): choose a valid existing destination label GUID.")
            }
            if ($mapping['ExistingLabelReviewed'] -ne $true -or -not $mapping['ExistingLabelEvidence']) {
                $errors.Add("$($definition.Key): existing destination label requires ExistingLabelReviewed=true and ExistingLabelEvidence after checking label meaning and protection.")
            }
        }
        if ($definition.Kind -eq 'LabelPublishing' -and $definition.Fields.ContainsKey('Priority')) {
            $warnings.Add("$($definition.Key): source publishing Priority=$($definition.Fields.Priority) is reference-only. Set-LabelPolicy has no -Priority parameter; review destination order explicitly in the portal or use its documented NextLabelPolicy/PreviousLabelPolicy commands.")
            if ($null -ne $mapping['Priority']) { $errors.Add("$($definition.Key): numeric publishing Priority overrides are not supported. Use documented publishing-policy ordering operations separately.") }
            if ($action -eq 'Create' -and
                ($mapping['PublishingOrderReviewed'] -ne $true -or -not $mapping['PublishingOrderEvidence'])) {
                $errors.Add("$($definition.Key): publication requires PublishingOrderReviewed=true and PublishingOrderEvidence accepting a manual destination ordering check.")
            }
        }
        if ($action -eq 'Create' -and @(@('AdvancedRule', 'LabelActions') | Where-Object { Test-PmMeaningful $definition.Fields[$_] }).Count) {
            if ($mapping['StructuredPayloadReviewed'] -ne $true -or -not $mapping['StructuredPayloadEvidence']) {
                $errors.Add("$($definition.Key): opaque AdvancedRule/LabelActions payload requires StructuredPayloadReviewed=true and StructuredPayloadEvidence after reviewing every tenant-bound setting.")
            }
        }
        $alertPending = $action -eq 'Create' -and $definition.ContainsKey('AlertReview')
        if ($alertPending) {
            $warnings.Add("$($definition.Key): this legacy staged package requires alert review acknowledgment. Supported alert settings are retained; the source identifier is not copied. Compare destination settings and test alert behavior, rather than assuming a separate alert policy must be created. Import will report ConfigurationVerifiedManualAlertReviewRequired, not Verified.")
            if ($mapping['ProtectionAlertReviewed'] -ne $true -or -not $mapping['ProtectionAlertEvidence']) {
                $errors.Add("$($definition.Key): legacy package alert review requires ProtectionAlertReviewed=true and ProtectionAlertEvidence describing the destination alert validation plan or results.")
            }
        }
        if ($definition.ParentKey -and $mappings.Objects[$definition.ParentKey].Action -eq 'Reuse' -and $action -eq 'Create') {
            $errors.Add("$($definition.Key): cannot add a new rule to a reused pre-existing policy. Reuse its existing rules or create a separate policy.")
        }
        if (-not $mapping.Name -or $mapping.Name -match '[\r\n]') { $errors.Add("$($definition.Key): a valid destination Name is required.") }
        $nameKey = "$($definition.Kind):$($mapping.Name)"
        if ($names.ContainsKey($nameKey)) { $errors.Add("Duplicate planned destination name '$nameKey'.") }
        $names[$nameKey] = $true
        $record = $journal.Objects[$definition.Key]
        if ($null -ne $record) {
            if ($record.State -eq 'Creating') {
                $errors.Add("$($definition.Key): interrupted during creation. Reconcile the destination manually before resuming; never guess whether creation succeeded.")
            } elseif ($record.DestinationId) {
                $resolved[$definition.Key] = [string]$record.DestinationId
                $status = 'ResumeVerify'
            }
        }
        if (-not $Offline) {
            $existing = @($destination[$definition.Kind])
            if ($action -eq 'Reuse' -or $resolved.ContainsKey($definition.Key)) {
                $id = if ($resolved.ContainsKey($definition.Key)) { $resolved[$definition.Key] } else { [string]$mapping.DestinationId }
                $found = @(Find-PmExistingObject $existing $id)
                if (-not $id -or $found.Count -ne 1) { $errors.Add("$($definition.Key): reuse/resume destination identity '$id' does not uniquely exist.") }
                if ($found.Count -eq 1 -and $action -ne 'Reuse' -and $definition.Kind -ne 'SensitiveInformationTypes' -and $found[0].Name -ne $mapping.Name) {
                    $errors.Add("$($definition.Key): journal destination name no longer matches.")
                }
                if ($found.Count -eq 1 -and $action -eq 'Reuse' -and $definition.ParentKey) {
                    $parentId = [string]$mappings.Objects[$definition.ParentKey].DestinationId
                    $parentIds = @(
                        foreach ($field in @('Policy', 'PolicyId', 'ParentPolicyId')) {
                            Get-PmIdentityValue $found[0][$field]
                        }
                    )
                    if ($parentId -notin $parentIds) {
                        $errors.Add("$($definition.Key): cannot verify that the reused rule belongs to its mapped existing policy.")
                    }
                }
            } elseif (@($existing | Where-Object { $_.Name -eq $mapping.Name }).Count) {
                $errors.Add("$($definition.Key): destination name already exists. Explicitly reuse or rename; updates are prohibited.")
            }
        }
        $parameters = @{}
        $setParameters = Get-PmSetParameters $definition $mapping "<created:$($definition.Key)>"
        $xmlPreview = ''
        if ($definition.Kind -eq 'SensitiveInformationTypes') {
            if ($action -eq 'Create') {
                $xmlPreview = Get-PmPreparedSitXml $package $definition $mapping $mappings
                if (-not $Offline) {
                    if (@(Find-PmExistingObject @($destination[$definition.Kind]) ([string]$mapping.DestinationId)).Count) {
                        if (-not $resolved.ContainsKey($definition.Key)) { $errors.Add("$($definition.Key): destination rule package ID already exists.") }
                    }
                    foreach ($id in $definition.EntityIds) {
                        if ($id -in $sitIds -and -not $resolved.ContainsKey($definition.Key)) {
                            $errors.Add("$($definition.Key): SIT entity ID $id already exists. Reuse an existing compatible package or prepare a separate supported source package.")
                        }
                    }
                }
            } elseif ($action -eq 'Reuse' -and -not $Offline) {
                foreach ($id in $definition.EntityIds) {
                    if ($id -notin $sitIds) { $errors.Add("$($definition.Key): reused package must expose original entity ID $id; entity-ID rewriting is not supported.") }
                }
            }
            $parameters = @{ FileData = "<validated XML: $($definition.XmlFile)>" }
        } elseif (-not $definition.ContainsKey('ExistingLabelReference')) {
            $previewIds = @{}
            foreach ($item in $package.Objects) { $previewIds[$item.Key] = "<created:$($item.Key)>" }
            $parameters = Get-PmCreateParameters $definition $mapping $replacements $previewIds (Get-PmExternalMap $mappings)
            if ($parameters.ContainsKey('AdvancedRule')) {
                $remainingLeaves = @(Get-PmLeaves $parameters.AdvancedRule)
                foreach ($reference in $definition.ExternalReferences) {
                    if ($reference -in $remainingLeaves -and $mappings.References.ContainsKey($reference) -and
                        $mappings.References[$reference].Reviewed -eq $true -and $mappings.References[$reference].Value -ne $reference) {
                        $errors.Add("$($definition.Key): advanced-rule reference '$reference' cannot be safely rewritten by the supported condition adapters. Preserve it only after confirming it is a literal, or use a supported condition/reused object.")
                    }
                }
            }
        }
        if (-not $Offline -and $action -eq 'Create' -and $status -ne 'DeferredPublication') {
            $spec = $script:PmSpecifications[$definition.Kind]
            $null = Assert-PmCommand $spec.New @($parameters.Keys)
            if ($setParameters.Count -gt 1) {
                $null = Assert-PmCommand $spec.Set @($setParameters.Keys)
            }
        }
        if (@(Get-PmLeaves $definition.Fields) -contains 'All') {
            $warnings.Add("$($definition.Key): an All scope is retained and will refer to ALL qualifying destination resources.")
        }
        if ($definition.Kind -eq 'SensitivityLabels' -and $definition.Fields['EncryptionEnabled']) {
            $warnings.Add("$($definition.Key): encryption configuration needs destination rights/key-service validation; protected source content is not migrated.")
        }
        if ($action -eq 'Reuse') { $resolved[$definition.Key] = [string]$mapping.DestinationId; $status = 'Reuse' }
        $steps.Add([pscustomobject]@{
            Key = $definition.Key; Kind = $definition.Kind; Name = $mapping.Name
            Action = $action; Status = $status; Command = $script:PmSpecifications[$definition.Kind].New
            Parameters = $parameters; Dependencies = @($definition.Dependencies)
            SetParameters = $setParameters
            SourcePriority = $definition.Fields['Priority']
            ManualAlertReviewRequired = $alertPending
            PreparedXml = $xmlPreview
        })
    }
    [pscustomobject]@{
        PackageId = $package.Manifest.PackageId; SourceTenantId = $package.Manifest.SourceTenantId
        DestinationTenantId = $mappings.DestinationTenantId; Online = (-not $Offline)
        CanImport = (-not $Offline -and $errors.Count -eq 0)
        BlockingErrors = @($errors); Warnings = @($warnings); Steps = @($steps)
        JournalPath = $JournalPath
    }
}

function Get-PmVerifiedObject {
    param($Definition, [string]$DestinationId, [hashtable]$Expected, [int]$Attempts, [int]$DelaySeconds)
    $spec = $script:PmSpecifications[$Definition.Kind]
    $lastMismatch = @()
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $parameters = @{ Identity = $DestinationId }
        if ($Definition.Kind -eq 'SensitivityLabels') { $parameters.IncludeDetailedLabelActions = $true }
        $found = @(Invoke-PmCommand $spec.Get $parameters)
        if ($found.Count -eq 1) {
            $actual = if ($Definition.Kind -eq 'SensitiveInformationTypes') {
                ConvertTo-PmSitRecord (Get-PmSitDefinition $found[0])
            } else { ConvertTo-PmData $found[0] }
            $actualIds = @(Get-PmIdentityValues $actual)
            if ($DestinationId -notin $actualIds) { throw "Read-back returned a different identity for '$DestinationId'." }
            $lastMismatch = @()
            foreach ($field in $Expected.Keys) {
                if ($field -eq 'Policy') {
                    $parentIds = @(
                        foreach ($parentField in @('Policy', 'PolicyId', 'ParentPolicyId')) {
                            Get-PmIdentityValue $actual[$parentField]
                        }
                    )
                    if ($Expected[$field] -notin $parentIds) { $lastMismatch += $field }
                } elseif ((Get-PmCanonicalJson $actual[$field]) -ne (Get-PmCanonicalJson $Expected[$field])) {
                    $lastMismatch += $field
                }
            }
            if (-not $lastMismatch.Count) { return $actual }
        } else { $lastMismatch = @('ObjectMissingOrAmbiguous') }
        if ($attempt -lt $Attempts -and $DelaySeconds) { Start-Sleep -Seconds $DelaySeconds }
    }
    throw "Read-back verification failed for '$($Definition.Name)': $($lastMismatch -join ', '). Object may exist; consult the journal before retrying."
}

function Import-PurviewMigrationPackage {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$MappingsPath,
        [Parameter(Mandatory)][guid]$DestinationTenantId,
        [Parameter(Mandatory)][guid]$ConfirmDestinationTenantId,
        [string]$JournalPath,
        [switch]$PublishLabels,
        [ValidateRange(1, 20)][int]$VerificationAttempts = 3,
        [ValidateRange(0, 60)][int]$VerificationDelaySeconds = 5
    )
    if ($DestinationTenantId -ne $ConfirmDestinationTenantId) { throw 'Explicit destination tenant confirmation does not match.' }
    $null = Get-PurviewMigrationSession -ExpectedTenantId $DestinationTenantId
    $package = Read-PmPackage $Path
    $mappings = Read-PmMappings $package $MappingsPath
    if ($DestinationTenantId -ne [guid]$mappings.DestinationTenantId) { throw 'Destination tenant does not match mappings.' }
    $plan = New-PurviewMigrationPlan -Path $Path -MappingsPath $MappingsPath -JournalPath $JournalPath -PublishLabels:$PublishLabels
    if (-not $plan.CanImport) { throw "Import preflight blocked:`n$($plan.BlockingErrors -join "`n")" }
    if ($WhatIfPreference) {
        $null = $PSCmdlet.ShouldProcess($DestinationTenantId, 'Execute migration plan (no service writes in preview)')
        return $plan
    }
    if (-not $PSCmdlet.ShouldProcess($DestinationTenantId, "Import $($package.Objects.Count) configuration objects; PublishLabels=$PublishLabels")) { return $plan }
    $JournalPath = $plan.JournalPath
    $journal = Read-PmJournal $package $mappings $JournalPath
    $resolved = @{}
    foreach ($key in $journal.Objects.Keys) {
        if ($journal.Objects[$key].DestinationId) { $resolved[$key] = $journal.Objects[$key].DestinationId }
    }
    $journal.Status = 'InProgress'
    Write-PmJson $JournalPath $journal
    try {
        foreach ($definition in (Get-PmOrderedObjects $package.Objects)) {
            $null = Get-PurviewMigrationSession -ExpectedTenantId $DestinationTenantId
            $mapping = $mappings.Objects[$definition.Key]
            if ($definition.Kind -eq 'LabelPublishing' -and -not $PublishLabels) { continue }
            if ($mapping.Action -eq 'Reuse') {
                $resolved[$definition.Key] = [string]$mapping.DestinationId
                $journal.Objects[$definition.Key] = @{ State = 'Reused'; DestinationId = $mapping.DestinationId; Name = $mapping.Name }
                Write-PmJson $JournalPath $journal
                continue
            }
            $spec = $script:PmSpecifications[$definition.Kind]
            $replacements = Get-PmReplacements $package $mappings $resolved
            if ($definition.Kind -eq 'SensitiveInformationTypes') {
                $xml = Get-PmPreparedSitXml $package $definition $mapping $mappings
                $preparedPath = Join-Path $package.Root "prepared-$($mapping.DestinationId).xml"
                if (-not $resolved.ContainsKey($definition.Key)) {
                    [IO.File]::WriteAllText($preparedPath, $xml, [Text.UTF8Encoding]::new($false))
                }
                $parameters = @{ FileData = [Text.Encoding]::UTF8.GetBytes($xml) }
                $expected = @{}
            } else {
                $parameters = Get-PmCreateParameters $definition $mapping $replacements $resolved (Get-PmExternalMap $mappings)
                $expected = $parameters.Clone()
                foreach ($field in $spec.SetOnly) {
                    if ($definition.Kind -eq 'LabelPublishing' -and $field -eq 'Priority') { continue }
                    if ($definition.Fields.ContainsKey($field)) {
                        $expected[$field] = if ($field -eq 'Priority') { Get-PmEffectivePriority $definition $mapping } else { $definition.Fields[$field] }
                    }
                }
            }
            if (-not $resolved.ContainsKey($definition.Key)) {
                $journal.Objects[$definition.Key] = @{ State = 'Creating'; DestinationId = ''; Name = $mapping.Name }
                Write-PmJson $JournalPath $journal
                $created = @(Invoke-PmCommand $spec.New $parameters)
                $id = if ($definition.Kind -eq 'SensitiveInformationTypes') { [string]$mapping.DestinationId }
                    elseif ($created.Count -eq 1) { Get-PmObjectId (ConvertTo-PmData $created[0]) }
                    else { throw "Create did not return one identifiable object for '$($definition.Name)'. Reconcile the Creating journal entry before resuming." }
                $resolved[$definition.Key] = $id
                $journal.Objects[$definition.Key].DestinationId = $id
                $journal.Objects[$definition.Key].State = 'Created'
                Write-PmJson $JournalPath $journal
            }
            $id = [string]$resolved[$definition.Key]
            $setParameters = Get-PmSetParameters $definition $mapping $id
            if ($setParameters.Count -gt 1) { $null = Invoke-PmCommand $spec.Set $setParameters }
            $actual = Get-PmVerifiedObject $definition $id $expected $VerificationAttempts $VerificationDelaySeconds
            if ($definition.Kind -eq 'SensitiveInformationTypes') {
                Assert-PmSitReadBack $actual $xml $definition.Name
            }
            $journal.Objects[$definition.Key].State = if ($definition.ContainsKey('AlertReview')) { 'ConfigurationVerifiedManualAlertReviewRequired' } else { 'Verified' }
            Write-PmJson $JournalPath $journal
        }
        $verification = @(Test-PurviewMigrationImport -Path $Path -MappingsPath $MappingsPath -JournalPath $JournalPath `
            -VerificationAttempts $VerificationAttempts -VerificationDelaySeconds $VerificationDelaySeconds)
        $deferred = @($package.Objects | Where-Object { $_.Kind -eq 'LabelPublishing' -and -not $PublishLabels })
        $manualOrder = @($package.Objects | Where-Object {
            $_.Kind -eq 'LabelPublishing' -and $_.Fields.ContainsKey('Priority') -and $PublishLabels -and $mappings.Objects[$_.Key].Action -eq 'Create'
        })
        $alertAffected = @($package.Objects | Where-Object { $_.ContainsKey('AlertReview') -and $mappings.Objects[$_.Key].Action -eq 'Create' })
        $existingLabels = @($package.Objects | Where-Object { $_.ContainsKey('ExistingLabelReference') })
        $journal.Status = if ($alertAffected.Count) { 'ConfigurationVerifiedManualAlertReviewRequired' }
            elseif ($deferred.Count) { 'VerifiedWithDeferredPublication' }
            elseif ($manualOrder.Count) { 'ConfigurationVerifiedManualPublishingOrderRequired' }
            elseif ($existingLabels.Count) { 'ConfigurationVerifiedReusedLabelsNotContentVerified' } else { 'Verified' }
        Write-PmJson $JournalPath $journal
    } catch {
        $journal.Status = 'Failed'
        $journal.LastError = $_.Exception.Message
        Write-PmJson $JournalPath $journal
        throw
    }
    [pscustomobject]@{
        Status = $journal.Status; JournalPath = $JournalPath; Objects = $journal.Objects
        DeferredPublication = @($deferred | ForEach-Object { $_.Key }); Verification = @($verification)
        ManualAlertReview = @($alertAffected | ForEach-Object { $_.Key })
        ExistingLabelReferences = @($existingLabels | ForEach-Object { $_.Key })
    }
}

function Test-PurviewMigrationImport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$MappingsPath,
        [string]$JournalPath,
        [ValidateRange(1, 20)][int]$VerificationAttempts = 3,
        [ValidateRange(0, 60)][int]$VerificationDelaySeconds = 5
    )
    $package = Read-PmPackage $Path
    $mappings = Read-PmMappings $package $MappingsPath
    $null = Get-PurviewMigrationSession -ExpectedTenantId $mappings.DestinationTenantId
    if (-not $JournalPath) { $JournalPath = Join-Path $package.Root "import-$($mappings.DestinationTenantId).journal.json" }
    if (-not (Test-Path -LiteralPath $JournalPath)) { throw 'No import journal exists to verify.' }
    $journal = Read-PmJournal $package $mappings $JournalPath
    $resolved = @{}
    foreach ($key in $journal.Objects.Keys) { $resolved[$key] = $journal.Objects[$key].DestinationId }
    $replacements = Get-PmReplacements $package $mappings $resolved
    foreach ($definition in (Get-PmOrderedObjects $package.Objects)) {
        if (-not $resolved.ContainsKey($definition.Key)) {
            [pscustomobject]@{ Key = $definition.Key; Status = 'NotImported' }
            continue
        }
        if ($mappings.Objects[$definition.Key].Action -eq 'Reuse') {
            $found = @(Invoke-PmCommand $script:PmSpecifications[$definition.Kind].Get @{ Identity = $resolved[$definition.Key] })
            if ($found.Count -ne 1) { throw "Reused dependency '$($definition.Key)' no longer uniquely exists." }
            $actual = if ($definition.Kind -eq 'SensitiveInformationTypes') {
                ConvertTo-PmSitRecord (Get-PmSitDefinition $found[0])
            } else { ConvertTo-PmData $found[0] }
            if ((Get-PmObjectId $actual) -ne $resolved[$definition.Key]) { throw "Reused dependency '$($definition.Key)' no longer uniquely exists." }
            [pscustomobject]@{ Key = $definition.Key; Status = 'ReusedExistsNotContentVerified' }
            continue
        }
        $expected = if ($definition.Kind -eq 'SensitiveInformationTypes') { @{} }
            else { Get-PmCreateParameters $definition $mappings.Objects[$definition.Key] $replacements $resolved (Get-PmExternalMap $mappings) }
        foreach ($field in $script:PmSpecifications[$definition.Kind].SetOnly) {
            if ($definition.Kind -eq 'LabelPublishing' -and $field -eq 'Priority') { continue }
            if ($definition.Fields.ContainsKey($field)) {
                $expected[$field] = if ($field -eq 'Priority') { Get-PmEffectivePriority $definition $mappings.Objects[$definition.Key] } else { $definition.Fields[$field] }
            }
        }
        $actual = Get-PmVerifiedObject $definition $resolved[$definition.Key] $expected $VerificationAttempts $VerificationDelaySeconds
        if ($definition.Kind -eq 'SensitiveInformationTypes') {
            Assert-PmSitReadBack $actual (Get-PmPreparedSitXml $package $definition $mappings.Objects[$definition.Key] $mappings) $definition.Name
        }
        [pscustomobject]@{
            Key = $definition.Key
            Status = if ($definition.ContainsKey('AlertReview')) {
                'ConfigurationVerifiedManualAlertReviewRequired'
            } elseif ($definition.Kind -eq 'LabelPublishing' -and $definition.Fields.ContainsKey('Priority')) {
                'ConfigurationVerifiedManualPublishingOrderRequired'
            } else { 'Verified' }
        }
    }
}
