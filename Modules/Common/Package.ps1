function Test-PmRuleReadSelected {
    param([hashtable]$RuleSelection, [string]$Kind, $Definition)
    if ($null -eq $RuleSelection) { return $true }
    if (-not $RuleSelection.ContainsKey($Kind)) { return $false }
    foreach ($selector in @($RuleSelection[$Kind])) {
        if ($selector -eq '*' -or $selector -in $Definition.Aliases -or $selector -eq $Definition.Key) { return $true }
    }
    return $false
}
function Get-PmCatalog {
    param([string[]]$Types, [hashtable]$RuleSelection, [switch]$AllowDlpAlertReview)
    $catalog = [Collections.Generic.List[object]]::new()
    foreach ($kind in @($Types | Select-Object -Unique)) {
        if (-not $script:PmSpecifications.ContainsKey($kind) -or $kind.EndsWith('Rule')) { throw "Unknown selectable type '$kind'." }
        $spec = $script:PmSpecifications[$kind]
        $parameters = @{}
        if ($kind -eq 'SensitivityLabels') { $parameters.IncludeDetailedLabelActions = $true }
        $rawObjects = @(Invoke-PmCommand $spec.Get $parameters)
        $recordNumber = 0
        foreach ($raw in $rawObjects) {
            $recordNumber++
            $responseType = if ($null -eq $raw) { '<null>' } else { $raw.GetType().FullName }
            try {
                $data = ConvertTo-PmData $raw
                if ($kind -eq 'SensitiveInformationTypes') {
                    if ('Microsoft Rule Package' -in @(Get-PmSitPackageNames $data)) { continue }
                    if ($data['SerializedClassificationRuleCollection'] -is [array] -and $data['SerializedClassificationRuleCollection'].Count) {
                        $definition = Get-PmSitDefinition $raw
                    } else {
                        $identity = Get-PmSitReadIdentity $data
                        $full = @(Invoke-PmCommand $spec.Get @{ Identity = $identity })
                        if ($full.Count -ne 1) { throw "Expected one complete SIT package for '$identity'." }
                        $definition = Get-PmSitDefinition $full[0]
                        if ($identity -notin $definition.Aliases) {
                            throw "SIT detail response does not match requested package '$identity'."
                        }
                    }
                    if ($definition.Name -eq 'Microsoft Rule Package') { continue }
                } else {
                    $definition = Get-PmDefinition $kind $raw -AllowUnsupported
                    if ($definition.UnsupportedFields.Count) {
                        $definition.UnsupportedFieldShapes = @(Get-PmUnsupportedFieldShapes $definition $raw)
                    }
                }
            } catch {
                throw [InvalidOperationException]::new(
                    "Source read failed: $($spec.Get), kind $kind, result #$recordNumber, response type $responseType. $($_.Exception.Message) No source objects were skipped; export is blocked.",
                    $_.Exception)
            }
            $catalog.Add($definition)
            if ($spec.ContainsKey('RuleKind') -and (Test-PmRuleReadSelected $RuleSelection $kind $definition)) {
                $ruleSpec = $script:PmSpecifications[$spec.RuleKind]
                $ruleNumber = 0
                foreach ($rule in @(Invoke-PmCommand $ruleSpec.Get @{ Policy = (Get-PmObjectId $data) })) {
                    $ruleNumber++
                    $responseType = if ($null -eq $rule) { '<null>' } else { $rule.GetType().FullName }
                    try {
                        $ruleDefinition = Get-PmDefinition $spec.RuleKind $rule $definition.Key -AllowUnsupported -AllowDlpAlertReview:$AllowDlpAlertReview
                        if ($ruleDefinition.UnsupportedFields.Count) {
                            $ruleDefinition.UnsupportedFieldShapes = @(Get-PmUnsupportedFieldShapes $ruleDefinition $rule)
                        }
                        $catalog.Add($ruleDefinition)
                    } catch {
                        throw [InvalidOperationException]::new(
                            "Source read failed: $($ruleSpec.Get), kind $($spec.RuleKind), parent policy '$($definition.Name)', result #$ruleNumber, response type $responseType. $($_.Exception.Message) No rules were skipped; export is blocked.",
                            $_.Exception)
                    }
                }
            }
        }
    }
    return ,@($catalog)
}

function Get-PurviewMigrationInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][guid]$SourceTenantId,
        [ValidateSet('SensitivityLabels', 'AutoLabeling', 'LabelPublishing', 'Dlp', 'SensitiveInformationTypes')]
        [string[]]$Types = @('SensitivityLabels', 'AutoLabeling', 'LabelPublishing', 'Dlp', 'SensitiveInformationTypes')
    )
    $null = Get-PurviewMigrationSession -ExpectedTenantId $SourceTenantId
    foreach ($definition in (Get-PmCatalog $Types -RuleSelection @{})) {
        if (-not $definition.ParentKey) {
            [pscustomobject]@{
                Type = $definition.Kind; Name = $definition.Name; SourceId = $definition.SourceId
                Key = $definition.Key; UnsupportedFields = @($definition.UnsupportedFields)
            }
        }
    }
}

function Get-PmAliasIndex {
    param([array]$Definitions)
    $index = @{}
    foreach ($definition in $Definitions) {
        if ($definition.Kind -notin @('SensitivityLabels', 'SensitiveInformationTypes')) { continue }
        foreach ($alias in $definition.Aliases) {
            if (-not $index.ContainsKey([string]$alias)) { $index[[string]$alias] = @() }
            $index[[string]$alias] += $definition.Key
        }
    }
    return $index
}

function Resolve-PmDependencies {
    param([array]$Definitions)
    $index = Get-PmAliasIndex $Definitions
    foreach ($definition in $Definitions) {
        $dependencies = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        if ($definition.ParentKey) { $null = $dependencies.Add($definition.ParentKey) }
        $spec = $script:PmSpecifications[$definition.Kind]
        foreach ($field in $spec.References) {
            foreach ($leaf in @(Get-PmLeaves $definition.Fields[$field])) {
                if ($index.ContainsKey($leaf)) {
                    $matches = @($index[$leaf] | Where-Object { $_ -ne $definition.Key } | Select-Object -Unique)
                    if ($matches.Count -gt 1) { throw "Ambiguous dependency '$leaf' in '$($definition.Name)'." }
                    foreach ($match in $matches) { $null = $dependencies.Add($match) }
                } elseif ($field -in @('ParentId', 'DefaultContentLabel', 'ApplySensitivityLabel', 'Labels') -and $leaf -ne [guid]::Empty.ToString()) {
                    $definition.UnresolvedReferences += "Unresolved label dependency '$leaf' in '$($definition.Name)' ($field)."
                }
            }
        }
        $definition.Dependencies = @($dependencies | Sort-Object)
    }
}

function Get-PmExternalReferences {
    param($Definition, [hashtable]$AliasIndex)
    $spec = $script:PmSpecifications[$Definition.Kind]
    if ($Definition.Kind -eq 'SensitiveInformationTypes') { return ,@($Definition.ExternalReferences) }
    $references = @()
    foreach ($field in $spec.External) {
        foreach ($leaf in @(Get-PmLeaves $Definition.Fields[$field])) {
            if ($leaf -in @('All', 'None', 'SiteAdmin', 'Owner', 'LastModifier', 'MatchedUser')) { continue }
            if ($AliasIndex.ContainsKey($leaf)) { continue }
            if ($field -eq 'AdvancedRule' -and $leaf -notmatch '(@|https?://|^[0-9a-fA-F-]{36}$)') { continue }
            $references += $leaf
        }
    }
    # Unknown GUIDs inside structured conditions can identify external classifier resources.
    foreach ($field in $spec.References) {
        foreach ($leaf in @(Get-PmLeaves $Definition.Fields[$field])) {
            if ($leaf -match '^[0-9a-fA-F-]{36}$' -and $leaf -ne [guid]::Empty.ToString() -and -not $AliasIndex.ContainsKey($leaf)) {
                $references += $leaf
            }
        }
    }
    if ($Definition.Kind -eq 'SensitivityLabels') {
        foreach ($leaf in @(Get-PmLeaves $Definition.Fields['LabelActions'])) {
            if ($leaf -match '(@|https?://|^[0-9a-fA-F-]{36}$)') { $references += $leaf }
        }
    }
    return ,@($references | Select-Object -Unique)
}

function Export-PurviewMigrationPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][guid]$SourceTenantId,
        [Parameter(Mandatory)][hashtable]$Selection,
        [Parameter(Mandatory)][string]$Path,
        [string]$NamePrefix = '',
        [switch]$AllowDlpAlertReview,
        [switch]$UseExistingDlpLabels
    )
    $session = Get-PurviewMigrationSession -ExpectedTenantId $SourceTenantId
    if (-not $Selection.Count) { throw 'Selection must contain at least one type and explicit object names/IDs (or *).' }
    $dlpOnly = $Selection.ContainsKey('Dlp') -and
        @($Selection.Keys | Where-Object { $_ -notin @('Dlp', 'SensitiveInformationTypes') }).Count -eq 0
    if ($UseExistingDlpLabels -and -not $dlpOnly) {
        throw 'UseExistingDlpLabels requires a DLP-only selection (optional separate SIT packages are allowed). Export label configuration and other solutions separately.'
    }
    $types = @(@($Selection.Keys) + @('SensitivityLabels') | Select-Object -Unique)
    $catalog = Get-PmCatalog $types -RuleSelection $Selection -AllowDlpAlertReview:$AllowDlpAlertReview
    if ($UseExistingDlpLabels) {
        foreach ($label in @($catalog | Where-Object Kind -eq 'SensitivityLabels')) {
            $label.Fields = @{ Name = $label.Name }
            $label.ParentKey = ''
            $label.UnsupportedFields = @()
            $label.UnresolvedReferences = @()
            $label.Remove('UnsupportedFieldShapes')
            $label.ExistingLabelReference = @{
                Kind = 'ExistingDestinationLabel'; Creatable = $false; ConfigurationExported = $false
            }
        }
    }
    Resolve-PmDependencies $catalog
    $byKey = @{}
    foreach ($item in $catalog) { $byKey[$item.Key] = $item }
    $included = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($kind in $Selection.Keys) {
        $selectors = @($Selection[$kind])
        if (-not $selectors.Count) { throw "Selection for $kind is empty; use '*' explicitly for all." }
        foreach ($selector in $selectors) {
            $matches = @($catalog | Where-Object {
                $_.Kind -eq $kind -and ($selector -eq '*' -or $selector -in $_.Aliases -or $selector -eq $_.Key)
            })
            if (-not $matches.Count) { throw "No $kind object matches '$selector'." }
            if ($selector -ne '*' -and $matches.Count -ne 1) { throw "Ambiguous selection '$selector'; select by SourceId." }
            foreach ($match in $matches) { $match.Selected = $true; $null = $included.Add($match.Key) }
        }
    }
    do {
        $before = $included.Count
        foreach ($key in @($included)) {
            foreach ($dependency in $byKey[$key].Dependencies) { $null = $included.Add($dependency) }
            foreach ($child in @($catalog | Where-Object { $_.ParentKey -eq $key })) { $null = $included.Add($child.Key) }
        }
    } while ($before -ne $included.Count)
    $definitions = @($included | Sort-Object | ForEach-Object { $byKey[$_] })
    $blocked = @($definitions | Where-Object { $_.UnsupportedFields.Count })
    if ($blocked.Count) {
        $details = @(foreach ($definition in $blocked) {
            $shapeDetail = if ($definition.ContainsKey('UnsupportedFieldShapes')) {
                " Value shapes (no payload values): $($definition.UnsupportedFieldShapes -join '; ')."
            } else { '' }
            "$($definition.Kind) '$($definition.Name)' has unsupported populated fields: $($definition.UnsupportedFields -join ', ').$shapeDetail"
        })
        $failure = [InvalidOperationException]::new(($details -join "`n") + "`nNo incomplete export will be certified.")
        $blockedLabels = @($blocked | Where-Object Kind -eq 'SensitivityLabels')
        if ($dlpOnly -and -not $UseExistingDlpLabels -and $blockedLabels.Count) {
            $failure.Data['ExistingDlpLabelsOptInAvailable'] = $true
            $failure.Data['ExistingDlpLabelCount'] = $blockedLabels.Count
        }
        throw $failure
    }
    foreach ($definition in $definitions) {
        if ($definition.UnresolvedReferences.Count) { throw ($definition.UnresolvedReferences -join "`n") }
    }
    $aliasIndex = Get-PmAliasIndex $catalog
    foreach ($definition in $definitions) { $definition.ExternalReferences = Get-PmExternalReferences $definition $aliasIndex }
    $root = [IO.Path]::GetFullPath($Path)
    if (Test-Path -LiteralPath $root) { throw "Export destination already exists: $root. Choose a new directory." }
    $null = New-Item -ItemType Directory -Path $root -ErrorAction Stop
    $files = @{}
    foreach ($definition in $definitions) {
        if ($definition.Kind -eq 'SensitiveInformationTypes') {
            $file = "sit-$([guid]$definition.SourceId).xml"
            [IO.File]::WriteAllBytes((Join-Path $root $file), $definition.XmlBytes)
            $definition.XmlFile = $file
            $definition.Remove('XmlContent')
            $definition.Remove('XmlBytes')
            $files[$file] = (Get-FileHash -LiteralPath (Join-Path $root $file) -Algorithm SHA256).Hash
        }
    }
    Write-PmJson (Join-Path $root 'objects.json') @($definitions)
    $files['objects.json'] = (Get-FileHash -LiteralPath (Join-Path $root 'objects.json') -Algorithm SHA256).Hash
    $objectMappings = @{}
    $referenceMappings = @{}
    foreach ($definition in $definitions) {
        $mapping = @{
            Action = 'Review'; Name = "$NamePrefix$($definition.Name)"; DestinationId = ''; DisplayName = $null
            Priority = $null
            StructuredPayloadReviewed = $false; StructuredPayloadEvidence = ''
            PublishingOrderReviewed = $false; PublishingOrderEvidence = ''
        }
        if ($definition.ContainsKey('AlertReview')) {
            $mapping.ProtectionAlertReviewed = $false; $mapping.ProtectionAlertEvidence = ''
        }
        if ($definition.ContainsKey('ExistingLabelReference')) {
            $mapping.Action = 'Reuse'; $mapping.Name = $definition.Name
            $mapping.ExistingLabelReviewed = $false; $mapping.ExistingLabelEvidence = ''
        }
        if ($definition.Kind -eq 'SensitiveInformationTypes') {
            $mapping.Name = "${NamePrefix}Migrated-$($definition.Name)"
            $mapping.DestinationId = [guid]::NewGuid().ToString()
        }
        $objectMappings[$definition.Key] = $mapping
        foreach ($reference in $definition.ExternalReferences) {
            $referenceMappings[$reference] = @{ Value = ''; Reviewed = $false; Evidence = '' }
        }
    }
    $manifest = @{
        SchemaVersion = 1; ToolVersion = $script:PmVersion
        PackageId = [guid]::NewGuid().ToString()
        SourceTenantId = $session.TenantId; ExportedAtUtc = [datetime]::UtcNow.ToString('o')
        ObjectCount = $definitions.Count; Files = $files
    }
    Write-PmJson (Join-Path $root 'mappings.json') @{
        SchemaVersion = 1; PackageId = $manifest.PackageId; DestinationTenantId = ''
        Objects = $objectMappings; References = $referenceMappings
    }
    $dlpInstructions = ''
    if ('DlpRule' -in $definitions.Kind) {
        $dlpInstructions += "   DLP ALERT SETTINGS: supported GenerateAlert, AlertProperties, ReportSeverityLevel and incident-report settings are retained when populated. The source-only ProtectionAlertId response identifier is not copied or sent to New-DlpComplianceRule. Compare destination Incident reports settings and test alert behavior before activation; read-back does not prove delivery or automatic identifier allocation.`n"
    }
    $existingLabels = @($definitions | Where-Object { $_.ContainsKey('ExistingLabelReference') })
    if ($existingLabels.Count) {
        $dlpInstructions += "   EXISTING DESTINATION LABELS: $($existingLabels.Count) label identity reference(s) only; label configuration was NOT exported. Select an existing destination label for each reference; Create is forbidden. Validate its meaning/protection independently and set ExistingLabelReviewed=true with ExistingLabelEvidence. Labels must exist before DLP import; no label is created or updated. Reused existence is not content equivalence.`n"
    }
    if ('DlpRule' -in $definitions.Kind -and 'SensitiveInformationTypes' -notin $definitions.Kind) {
        $dlpInstructions += "   For DLP custom classifier references, confirm the destination SIT already exists or export/import its package separately first. If it already exists, map references to its validated destination entity ID; do not create a duplicate.`n"
    }
    $alertRules = @($definitions | Where-Object { $_.ContainsKey('AlertReview') })
    $alertInstructions = ''
    if ($alertRules.Count) {
        $alertInstructions = "   MANUAL ALERT REVIEW (legacy explicit opt-in): $($alertRules.Count) DLP rule(s) retain the older review contract. Supported alert settings are included; the source response identifier is not copied. For each affected Objects entry set ProtectionAlertReviewed=true and ProtectionAlertEvidence documenting destination alert validation plans/results. Compare Incident reports settings and test alert behavior; do not assume a separate alert policy must be created. Import status remains ConfigurationVerifiedManualAlertReviewRequired for compatibility.`n"
    }
    $instructions = @"
Export completed from tenant $($session.TenantId).
Objects: $($definitions.Count). Supported label dependencies are included. Custom SIT packages are included only when explicitly selected.
1. Protect this directory: it contains organizational security configuration.
2. Package folder: $root
   manifest.json records identity/hashes; objects.json contains definitions; sit-*.xml is original XML.
   mappings.json is editable destination instructions; NEXT-STEPS.txt is this handoff.
   Do NOT edit source definitions, XML or hashes. Keep exports out of GitHub.
3. Disconnect the source, or close this dedicated pwsh and start a fresh process.
4. Run Start-PurviewMigration.ps1 from the toolkit directory.
   Choose OPERATION 3 (preview/import/resume), then open the package folder shown above.
   Enter at the mappings-file prompt keeps this package's mappings.json.
5. Sign in to the destination: no tenant-ID lookup is required.
   Confirm the actual displayed account and discovered tenant; it must differ from the source.
6. Follow guided Create/Reuse, naming and external-reference choices.
   Reuse never updates existing objects or proves semantic equivalence.
   The wizard fills the destination tenant ID after confirmation, before first import only.
   For complex settings, follow the exact manual-file review handoff and supply real evidence.
   No automatic approval of AdvancedRule, LabelActions, protection dependencies or publishing order.
$dlpInstructions$alertInstructions
7. Review preflight and last-preview.json (created by the wizard). Resolve all blockers.
   Decline execution for a no-service-write trial. Only type IMPORT when ready for destination writes.
8. Use operation 5 for read-back; operation 4 explicitly publishes labels (typed PUBLISH).
   Publication can expose labels/settings to users and can create other pending mapped objects.
   DLP remains disabled; auto-labeling remains in simulation. Review before manual activation.
9. After import starts, mappings and journal are bound. Resume with unchanged instructions.
   Never remove a journal or guess whether an interrupted Creating operation succeeded.
   Journal: import-<destination tenant>.journal.json; prepared-*.xml is separate destination XML.
See docs\CUSTOMER-GUIDE.md for XML boundaries, permissions, examples, and recovery.
"@
    [IO.File]::WriteAllText((Join-Path $root 'NEXT-STEPS.txt'), $instructions)
    Write-PmJson (Join-Path $root 'manifest.json') $manifest
    $null = Test-PurviewMigrationPackage -Path $root
    [pscustomobject]@{ Path = $root; PackageId = $manifest.PackageId; ObjectCount = $definitions.Count; Status = 'Exported'; NextSteps = (Join-Path $root 'NEXT-STEPS.txt'); ManualAlertReviewRules = $alertRules.Count; ExistingLabelReferences = $existingLabels.Count }
}

function Read-PmPackage {
    param([string]$Path)
    $root = [IO.Path]::GetFullPath($Path)
    if ((Get-Item -LiteralPath $root -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Package root must not be a reparse point.'
    }
    foreach ($name in @('manifest.json', 'objects.json')) {
        $item = Get-Item -LiteralPath (Join-Path $root $name) -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse-point file rejected: $name." }
    }
    $manifest = Read-PmJson (Join-Path $root 'manifest.json')
    if ($manifest.SchemaVersion -ne 1) { throw "Unsupported package schema '$($manifest.SchemaVersion)'." }
    $null = [guid]$manifest.PackageId
    $null = [guid]$manifest.SourceTenantId
    if (-not $manifest.Files.ContainsKey('objects.json')) { throw 'Manifest does not hash objects.json.' }
    foreach ($name in $manifest.Files.Keys) {
        if ($name -ne 'objects.json' -and $name -notmatch '^sit-[0-9a-fA-F-]{36}\.xml$') { throw "Unsafe or unexpected package filename '$name'." }
        $file = Get-Item -LiteralPath (Join-Path $root $name) -ErrorAction Stop
        if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Invalid package file '$name'." }
        if ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne $manifest.Files[$name]) {
            throw "Hash mismatch: $name. Use the original export; edit mappings.json, not source definitions."
        }
    }
    $definitions = @(Read-PmJson (Join-Path $root 'objects.json'))
    if (-not $definitions.Count -or $definitions.Count -ne $manifest.ObjectCount) { throw 'Package object count is invalid.' }
    $keys = @{}
    foreach ($definition in $definitions) {
        foreach ($field in @('Key', 'Kind', 'SourceId', 'Name', 'Fields', 'Dependencies', 'Aliases', 'ExternalReferences', 'ParentKey', 'UnsupportedFields')) {
            if (-not $definition.ContainsKey($field)) { throw "Object is missing required field '$field'." }
        }
        if (-not $script:PmSpecifications.ContainsKey($definition.Kind)) { throw "Unsupported kind '$($definition.Kind)'." }
        if (@($definition.UnsupportedFields).Count) { throw "Package contains unsupported fields in '$($definition.Name)'." }
        if ($definition.ContainsKey('ExistingLabelReference')) {
            $reference = $definition.ExistingLabelReference
            if ($definition.Kind -ne 'SensitivityLabels' -or $reference -isnot [hashtable] -or
                $reference.Count -ne 3 -or $reference['Kind'] -ne 'ExistingDestinationLabel' -or
                $reference['Creatable'] -isnot [bool] -or $reference.Creatable -ne $false -or
                $reference['ConfigurationExported'] -isnot [bool] -or $reference.ConfigurationExported -ne $false -or
                $definition.Fields.Count -ne 1 -or $definition.Fields['Name'] -ne $definition.Name -or
                @($definition.Dependencies).Count -or $definition.ParentKey -or @($definition.ExternalReferences).Count) {
                throw "Invalid existing-label identity reference in '$($definition.Name)'. Label configuration is not available for creation."
            }
        }
        if ($definition.ContainsKey('AlertReview')) {
            $review = $definition.AlertReview
            if ($definition.Kind -ne 'DlpRule' -or $review -isnot [hashtable] -or $review.Kind -ne 'DlpProtectionAlert' -or
                $review.Creatable -ne $false -or $review.Status -ne 'ManualAlertReviewPending' -or
                [string]$review.SourceReferenceSha256 -notmatch '^[0-9A-Fa-f]{64}$') {
                throw "Invalid manual alert review marker in '$($definition.Name)'."
            }
        }
        if ($keys.ContainsKey($definition.Key)) { throw "Duplicate object key '$($definition.Key)'." }
        $keys[$definition.Key] = $true
        if ($definition.Kind -eq 'SensitiveInformationTypes') {
            if (-not $manifest.Files.ContainsKey($definition.XmlFile)) { throw 'SIT XML file is not in the manifest.' }
            $null = Read-PmRuleXml -Bytes ([IO.File]::ReadAllBytes((Join-Path $root $definition.XmlFile)))
        } else {
            $spec = $script:PmSpecifications[$definition.Kind]
            foreach ($field in $definition.Fields.Keys) {
                if ($field -notin @($spec.Fields + $spec.SetOnly)) { throw "Unsupported imported field '$field' in '$($definition.Name)'." }
            }
        }
    }
    foreach ($definition in $definitions) {
        foreach ($dependency in $definition.Dependencies) {
            if (-not $keys.ContainsKey($dependency)) { throw "Missing dependency '$dependency'." }
        }
    }
    @{ Root = $root; Manifest = $manifest; Objects = $definitions }
}

function Test-PurviewMigrationPackage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $package = Read-PmPackage $Path
    [pscustomobject]@{
        Valid = $true; PackageId = $package.Manifest.PackageId
        SourceTenantId = $package.Manifest.SourceTenantId
        ObjectCount = $package.Objects.Count
    }
}
