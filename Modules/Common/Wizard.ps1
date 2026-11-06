function Write-PmWizardSection {
    param([string]$Title)
    Write-Host "`n$('-' * 72)`n$Title`n$('-' * 72)" -ForegroundColor Cyan
}

function Write-PmWizardNote {
    param([string]$Text)
    Write-Host ("  - " + ($Text -replace '\r?\n', "`n  - ")) -ForegroundColor Gray
}

function Read-PmChoice {
    param([string]$Prompt, [string[]]$Allowed)
    while ($true) {
        $answer = (Read-Host $Prompt).Trim()
        if ($answer -eq 'q' -and 'q' -notin $Allowed) {
            throw [OperationCanceledException]::new('Cancelled; no further changes will be made.')
        }
        if ($answer -in $Allowed) { return $answer }
        Write-Warning "Choose one of: $($Allowed -join ', '). Q cancels the operation."
    }
}

function Read-PmWizardText {
    param([string]$Prompt, [string]$Help, [string]$Default, [switch]$AllowEmpty)
    Write-PmWizardNote $Help
    while ($true) {
        $answer = (Read-Host "$Prompt (Q cancels)").Trim()
        if ($answer -eq 'q') { throw [OperationCanceledException]::new('Operation cancelled.') }
        if (-not $answer -and $Default) { return $Default }
        if ($answer -or $AllowEmpty) { return $answer }
        Write-Warning 'A value is required; there is no automatic default for this input.'
    }
}

function Read-PmWizardPath {
    param([switch]$NewExport, [switch]$File, [string]$Default)
    $help = if ($NewExport) {
        'Choose a NEW filesystem folder for exported configuration, not a SharePoint URL or XML filename.
Example: C:\PurviewExports\Demo-DLP-Run01 (an example only; no default is selected).
The tool creates the final folder and writes definitions, mappings and next-step instructions there.
Do not create the final folder beforehand. Existing folders/files are never overwritten.
Exports contain sensitive organizational security configuration: use approved restricted storage.
Paths may contain spaces; pasted surrounding quotes are accepted. Relative paths resolve from your current directory.'
    } elseif ($File) {
        "Choose the existing destination instructions JSON file, not objects.json or an XML file.
Enter keeps: $Default. This file may be edited only BEFORE an import starts."
    } else {
        "Choose the existing export folder containing manifest.json, objects.json and mappings.json.
Do not select an individual file or a SharePoint URL.$(if ($Default) { "`nEnter keeps: $Default" })"
    }
    Write-PmWizardNote $help
    while ($true) {
        $answer = Read-PmWizardText -Prompt $(if ($NewExport) { 'New export folder' } elseif ($File) { 'Mappings file' } else { 'Existing package folder' }) `
            -Help 'Enter a filesystem path; Q returns to the operation menu.' -Default $Default
        $answer = $answer.Trim([char[]]@('"', "'"))
        try {
            if ($answer -match '^[a-zA-Z]+://' -or $answer -match '[*?]') { throw 'Enter a filesystem path, not a URL or wildcard.' }
            foreach ($part in $answer.Split([char[]]@('\', '/'), [StringSplitOptions]::RemoveEmptyEntries)) {
                if ($part -notin @('.', '..') -and ($part.EndsWith('.') -or $part.EndsWith(' '))) {
                    throw "Windows names must not end in a dot or space: '$part'."
                }
            }
            $provider = $null
            $drive = $null
            $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($answer, [ref]$provider, [ref]$drive)
            if ($provider.Name -ne 'FileSystem') { throw 'Choose a FileSystem path, not another PowerShell provider.' }
            $path = [IO.Path]::GetFullPath($resolved)
            if (-not [IO.Path]::IsPathRooted($path)) { throw 'The filesystem path could not be resolved.' }
            foreach ($part in $path.Substring([IO.Path]::GetPathRoot($path).Length).Split('\', [StringSplitOptions]::RemoveEmptyEntries)) {
                if ($part.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $part.EndsWith('.') -or $part.EndsWith(' ') -or
                    $part -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$') {
                    throw "Invalid Windows folder/file name '$part'."
                }
            }
            $exists = Test-Path -LiteralPath $path -ErrorAction Stop
            if ($NewExport) {
                if ($exists) { throw 'That folder or file already exists. Choose a NEW final folder; the tool creates it.' }
                $parent = [IO.Path]::GetPathRoot($path)
                if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw "Drive/share is unavailable: $parent" }
            } elseif (-not $exists -or ($File -and -not (Test-Path -LiteralPath $path -PathType Leaf)) -or
                (-not $File -and -not (Test-Path -LiteralPath $path -PathType Container))) {
                throw 'The requested file/folder does not exist or is the wrong type.'
            }
            Write-Host "Resolved path: $path" -ForegroundColor Green
            return $path
        } catch {
            Write-Warning "Path not accepted: $($_.Exception.Message) Correct the path, or Q to cancel."
        }
    }
}

function Read-PmWizardSelection {
    param([string]$Prompt, [int]$Count, [switch]$AllowSkip)
    Write-PmWizardNote "Enter numbers separated by commas, or * for all.$(if ($AllowSkip) { ' Enter skips this solution.' }) Q cancels."
    while ($true) {
        $answer = Read-PmWizardText $Prompt 'Selections refer only to the numbered list immediately above.' -AllowEmpty:$AllowSkip
        if (-not $answer) { return }
        if ($answer -eq '*') { return 0..($Count - 1) }
        $indices = @()
        $valid = $true
        foreach ($part in $answer.Split(',')) {
            $number = 0
            if (-not [int]::TryParse($part.Trim(), [ref]$number) -or $number -lt 1 -or $number -gt $Count) { $valid = $false; break }
            $indices += $number - 1
        }
        if ($valid) { return $indices | Select-Object -Unique }
        Write-Warning "Use numbers from 1 to $Count. Your earlier selections are retained."
    }
}

function Connect-PmWizardTenant {
    param([string]$Role, [string]$ExcludedTenantId)
    $purpose = if ($Role -eq 'Source') { 'the tenant you are exporting FROM (read-only)' } else { 'the different tenant you are importing INTO' }
    Write-Host "Sign in to $purpose." -ForegroundColor White
    Write-PmWizardNote 'You do NOT need to look up a tenant ID. After Microsoft sign-in/MFA, check the account and tenant displayed below.'
    while ($true) {
        $connections = @(Get-ConnectionInformation -ErrorAction Stop | Where-Object { $_.State -eq 'Connected' -and $_.IsEopSession -eq $true })
        $session = $null
        if ($connections.Count) {
            $session = Get-PurviewMigrationSession
            Write-Host "Existing compliance session: account $($session.UserPrincipalName), tenant $($session.TenantId)." -ForegroundColor Yellow
            $action = Read-PmChoice 'Y reuse this session; S disconnect and sign in to a different tenant; Q cancel' @('y', 's', 'q')
            if ($action -eq 'q') { throw [OperationCanceledException]::new('Sign-in cancelled.') }
            if ($action -eq 's') {
                Disconnect-PurviewMigrationTenant -Confirm:$false
                $session = $null
            }
        }
        if (-not $session) {
            $account = Read-PmWizardText "$Role admin sign-in email (optional)" "Use the admin sign-in email for $purpose, for example admin@contoso.onmicrosoft.com.`nEnter opens Microsoft sign-in so you can choose your account there instead.`nThe email suggests an account; it does not select or verify the tenant. SSO may reuse an account. Always check the confirmed identity below." -AllowEmpty
            $session = Connect-PurviewMigrationTenant -UserPrincipalName $account
        }
        Write-PmWizardSection "$Role identity - check before continuing"
        Write-Host "Authenticated $Role account: $($session.UserPrincipalName)" -ForegroundColor Green
        Write-Host "Discovered $Role tenant ID: $($session.TenantId)" -ForegroundColor Green
        if ($ExcludedTenantId -and $session.TenantId -eq $ExcludedTenantId) {
            Write-Warning 'This is the SOURCE tenant. Import requires a different destination. Choose S to switch on the next prompt.'
            continue
        }
        $answer = Read-PmChoice "Is this the intended $Role tenant? Y confirm; N choose another session; Q cancel" @('y', 'n', 'q')
        if ($answer -eq 'q') { throw [OperationCanceledException]::new('Tenant confirmation cancelled.') }
        if ($answer -eq 'y') { return $session }
    }
}

function Get-PmWizardManualReviews {
    param($Package, $Mappings)
    foreach ($definition in $Package.Objects) {
        $entry = $Mappings.Objects[$definition.Key]
        $complex = @($definition.Fields.Keys | Where-Object {
            ($_ -in @('AdvancedRule', 'LabelActions') -or $_ -match '^Encryption' -or
                ($definition.Kind -eq 'LabelPublishing' -and $_ -in @('Settings', 'AdvancedSettings'))) -and
            (Test-PmMeaningful $definition.Fields[$_])
        })
        if ($entry.Action -eq 'Create' -and $complex.Count -and
            ($entry.StructuredPayloadReviewed -ne $true -or -not $entry.StructuredPayloadEvidence)) {
            "$($definition.Key): review $($complex -join ', ') in objects.json and prepared preview; set StructuredPayloadReviewed=true and StructuredPayloadEvidence only after validating destination semantics, scopes and protection dependencies."
        }
        if ($entry.Action -eq 'Create' -and $definition.ContainsKey('AlertReview') -and
            ($entry['ProtectionAlertReviewed'] -ne $true -or -not $entry['ProtectionAlertEvidence'])) {
            "$($definition.Key): this legacy staged package requires ProtectionAlertReviewed=true and ProtectionAlertEvidence documenting destination alert validation. Supported alert settings are retained; do not assume a separate alert policy must be created. Import will report ConfigurationVerifiedManualAlertReviewRequired."
        }
        if ($definition.ContainsKey('ExistingLabelReference') -and
            ($entry.Action -ne 'Reuse' -or -not $entry.DestinationId -or
                $entry['ExistingLabelReviewed'] -ne $true -or -not $entry['ExistingLabelEvidence'])) {
            "$($definition.Key): label configuration was NOT exported. Choose Action Reuse and an existing destination label GUID; set ExistingLabelReviewed=true and ExistingLabelEvidence only after checking its meaning and protection. Create is forbidden."
        }
        if ($entry.Action -eq 'Create' -and $definition.Kind -eq 'LabelPublishing' -and $definition.Fields.ContainsKey('Priority') -and
            ($entry.PublishingOrderReviewed -ne $true -or -not $entry.PublishingOrderEvidence)) {
            "$($definition.Key): source Priority is reference-only. Set PublishingOrderReviewed=true and PublishingOrderEvidence accepting a manual destination ordering check; do NOT set numeric Priority. Set-LabelPolicy has no -Priority."
        }
    }
}

function Edit-PmWizardMappings {
    param($Package, [string]$Path, $Destination)
    $mappings = Read-PmJson $Path
    if ($mappings.SchemaVersion -ne 1 -or $mappings.PackageId -ne $Package.Manifest.PackageId) { throw 'Mappings do not belong to this package/schema.' }
    if ($mappings.DestinationTenantId -and $mappings.DestinationTenantId -ne $Destination.TenantId) {
        throw 'Mappings target a different destination. Sign in to the intended tenant; do not overwrite a destination binding.'
    }
    $journalPath = Join-Path $Package.Root "import-$($Destination.TenantId).journal.json"
    $journals = @(Get-ChildItem -LiteralPath $Package.Root -Filter '*.journal.json' -File)
    if ($journals.Count) {
        if (-not (Test-Path -LiteralPath $journalPath)) { throw 'A journal exists under a nonstandard path. Use advanced commands with the original -JournalPath and unchanged mappings; the wizard cannot guess a resume journal.' }
        $bound = Read-PmMappings $Package $Path
        $null = Read-PmJournal $Package $bound $journalPath
        Write-PmWizardNote "Resume: mappings are journal-bound and READ-ONLY. Using $Path"
        Write-PmWizardNote 'Changed mappings must be restored from the original; never remove a journal or guess whether an interrupted creation succeeded.'
        return $true
    }
    Write-PmWizardSection "Destination mappings: $($Destination.UserPrincipalName), tenant $($Destination.TenantId)."
    Write-PmWizardNote 'Create makes a NEW object; Reuse checks an existing identity, never updates it and does not certify equivalent content.'
    Write-PmWizardNote 'New rules cannot be attached to a reused pre-existing policy. Reuse its compatible rules or create a separate policy.'
    Write-Warning 'An exported All scope remains All in this destination. This wizard does not automatically narrow it to a test group.'
    if ((Read-PmChoice 'Guide mappings now? Y guided choices; N keep file as-is for manual review; Q cancel' @('y', 'n')) -eq 'y') {
        $mappings.DestinationTenantId = $Destination.TenantId
        $inventory = Get-PmDestinationInventory $Package.Objects
        foreach ($definition in (Get-PmOrderedObjects $Package.Objects)) {
            $entry = $mappings.Objects[$definition.Key]
            Write-PmWizardSection "$($definition.Kind): $($definition.Name) [$($definition.Key)]"
            Write-PmWizardNote "Current action: $($entry.Action); name: $($entry.Name). Included dependencies and policy rules also require a choice."
            $referenceOnly = $definition.ContainsKey('ExistingLabelReference')
            if ($referenceOnly) {
                Write-Warning 'This is a label identity reference ONLY, not exported label configuration. Choose an existing destination label; no label will be created or updated.'
            }
            do {
                $action = if ($referenceOnly) {
                    Read-PmChoice 'R select existing destination label; K keep reviewed mapping; M handle manually; Q cancel' @('r', 'k', 'm', 'q')
                } else {
                    Read-PmChoice 'C create; R reuse an existing object; K keep reviewed current choice; M handle manually; Q cancel' @('c', 'r', 'k', 'm', 'q')
                }
                $items = @()
                if ($action -eq 'r') {
                    $items = @($inventory[$definition.Kind])
                    if (-not $items.Count) { Write-Warning 'No existing destination objects of this kind. Choose Create or leave the choice for manual review; no reuse identity will be invented.' }
                }
            } while ($action -eq 'r' -and -not $items.Count)
            if ($action -eq 'q') { throw [OperationCanceledException]::new('Mapping edits cancelled; unsaved choices discarded.') }
            if ($action -in @('k', 'm')) { continue }
            if ($action -eq 'r') {
                for ($i = 0; $i -lt $items.Count; $i++) { Write-Host "$($i + 1) $($items[$i].Name) [$(Get-PmObjectId $items[$i])]" }
                do {
                    $indices = @(Read-PmWizardSelection 'Existing destination object number (choose exactly one)' $items.Count)
                    if ($indices.Count -ne 1) { Write-Warning 'Reuse requires exactly one existing object.' }
                } until ($indices.Count -eq 1)
                $entry.DestinationId = Get-PmObjectId $items[$indices[0]]
                $entry.Name = [string]$items[$indices[0]].Name
                $entry.Action = 'Reuse'
                if ($referenceOnly) {
                    $entry.ExistingLabelReviewed = $false
                    $entry.ExistingLabelEvidence = ''
                    Write-PmWizardNote 'Selecting a label verifies identity only. Confirm that this is the intended destination counterpart, including its meaning, scope and protection. Display-name similarity alone is not proof.'
                    if ((Read-PmChoice 'Have you independently reviewed this destination label? (y/n; Q cancels)' @('y', 'n')) -eq 'y') {
                        $entry.ExistingLabelEvidence = Read-PmWizardText 'Destination label review evidence' 'Describe how you checked the label meaning, scope and protection. No automatic equivalence check is claimed.'
                        $entry.ExistingLabelReviewed = $true
                    }
                }
                continue
            }
            if ($definition.Kind -eq 'SensitiveInformationTypes') {
                if ($entry.Action -eq 'Reuse') { $entry.DestinationId = [guid]::NewGuid().ToString() }
                Write-Host "Whole SIT package: new package ID $($entry.DestinationId); original entity IDs are preserved. Collisions block; no merge/overwrite."
            } else { $entry.DestinationId = '' }
            $entry.Action = 'Create'
            $entry.Name = Read-PmWizardText 'Destination name' "Enter keeps '$($entry.Name)'. Choose a unique name: existing objects are never overwritten." -Default $entry.Name
            if ($definition.Kind -eq 'SensitivityLabels') {
                $display = Read-PmWizardText 'Label display name' 'Optional display text override, separate from the internal name. Enter retains the current override/source display text.' -AllowEmpty
                if ($display) { $entry.DisplayName = $display }
            }
            if ($definition.Fields.ContainsKey('Priority') -and $definition.Kind -ne 'LabelPublishing') {
                while ($true) {
                    $priority = Read-PmWizardText 'Destination priority' "Source priority: $($definition.Fields.Priority); current override: $($entry.Priority). Enter keeps current; SOURCE clears override; otherwise a nonnegative integer. Review selective-import ordering." -AllowEmpty
                    if (-not $priority) { break }
                    if ($priority -eq 'source') { $entry.Priority = $null; break }
                    $number = 0
                    if ([int]::TryParse($priority, [ref]$number) -and $number -ge 0) { $entry.Priority = $number; break }
                    Write-Warning 'Priority must be a nonnegative integer, SOURCE, or Enter.'
                }
            }
        }
        foreach ($reference in @($mappings.References.Keys | Sort-Object)) {
            $entry = $mappings.References[$reference]
            Write-PmWizardSection "External reference: $reference; current destination: $($entry.Value); reviewed: $($entry.Reviewed)"
            Write-PmWizardNote 'This can identify a user/group, site, domain, dictionary, protection service or XML resource. Confirm scope and semantics in the destination.'
            Write-PmWizardNote 'No automatic resource lookup is claimed: review evidence is YOUR attestation. For a DLP custom classifier, use the already-migrated destination entity ID if present; otherwise export/import its SIT package separately first. Do not guess XML entity IDs.'
            $action = Read-PmChoice 'E enter/review destination value; K keep current; M handle manually; Q cancel' @('e', 'k', 'm', 'q')
            if ($action -eq 'q') { throw [OperationCanceledException]::new('Mapping edits cancelled; unsaved choices discarded.') }
            if ($action -ne 'e') { continue }
            $entry.Value = Read-PmWizardText 'Exact destination reference value' 'Enter the full destination identifier, or the unchanged value only if independently validated. No substring replacement.' -Default $entry.Value
            $entry.Reviewed = $false
            $entry.Evidence = ''
            if ((Read-PmChoice 'Have you independently validated this value and its scope? (y/n; Q cancel)' @('y', 'n')) -eq 'y') {
                $entry.Evidence = Read-PmWizardText 'Destination validation evidence' 'Describe what was checked, how, and any remaining dependencies. This is not an API verification result.'
                $entry.Reviewed = $true
            }
        }
        Write-PmWizardSection "Proposed local mapping changes for tenant $($mappings.DestinationTenantId):"
        foreach ($key in @($mappings.Objects.Keys | Sort-Object)) {
            $entry = $mappings.Objects[$key]
            Write-Host "$key => $($entry.Action): $($entry.Name) [$($entry.DestinationId)]; display override=$($entry.DisplayName); priority override=$($entry.Priority); structured reviewed=$($entry.StructuredPayloadReviewed); publishing order reviewed=$($entry.PublishingOrderReviewed); alert review acknowledged=$($entry['ProtectionAlertReviewed'])"
        }
        foreach ($key in @($mappings.References.Keys | Sort-Object)) {
            $entry = $mappings.References[$key]
            Write-Host "Reference $key => $($entry.Value); reviewed=$($entry.Reviewed); evidence=$($entry.Evidence)"
        }
        if ((Read-PmChoice "Save these destination instructions to ${Path}? (y/n; Q cancel)" @('y', 'n')) -ne 'y') {
            throw [OperationCanceledException]::new('Mappings were not saved.')
        }
        Write-PmJson $Path $mappings
    }
    while ($true) {
        $unbound = Read-PmJson $Path
        if (-not $unbound.DestinationTenantId) {
            Write-Warning "Manual handoff: edit $Path before importing."
            Write-PmWizardNote "Set DestinationTenantId to the confirmed destination $($Destination.TenantId); choose Objects actions/names and review References values/evidence."
            Write-PmWizardNote 'Do not edit source definitions/XML. Save and return with operation 3 using the same paths; no service writes have occurred.'
            return $false
        }
        $mappings = Read-PmMappings $Package $Path
        if ($mappings.DestinationTenantId -ne $Destination.TenantId) { throw 'Mappings no longer match the confirmed destination.' }
        $reviews = @(Get-PmWizardManualReviews $Package $mappings)
        if (-not $reviews.Count) { return $true }
        Write-PmWizardSection 'MANUAL REVIEW - complete before import'
        Write-Warning "Manual review required in: $Path"
        foreach ($review in $reviews) { Write-PmWizardNote "Objects entry $review" }
        Write-PmWizardNote "Source reference: $(Join-Path $Package.Root 'objects.json'). Do NOT edit source definitions, original XML or manifest hashes."
        $previewPath = Join-Path $Package.Root 'last-preview.json'
        try {
            $reviewPlan = New-PurviewMigrationPlan -Path $Package.Root -MappingsPath $Path
            Write-PmJson $previewPath $reviewPlan
            Write-PmWizardNote "Review exact prepared parameters/warnings/blockers in $previewPath. A saved preview is NOT import approval."
        } catch {
            Write-Warning "Unable to prepare review preview: $($_.Exception.Message) No import approval is assumed. Correct instructions or prepare a supported source package."
        }
        Write-PmWizardNote "To inspect/retry in PowerShell: New-PurviewMigrationPlan -Path '$($Package.Root.Replace("'", "''"))' -MappingsPath '$($Path.Replace("'", "''"))' | ConvertTo-Json -Depth 100"
        Write-PmWizardNote 'Prepared XML is separate from original XML. Incompatible resources/entity IDs need a supported source package, not edits to hashed XML.'
        Write-PmWizardNote 'Example inside the indicated Objects entry: "StructuredPayloadReviewed": true, "StructuredPayloadEvidence": "Reviewed each destination reference and protection dependency in the prepared parameters". Replace this with your actual review; do not copy it as approval.'
        Write-PmWizardNote 'Save only reviewed destination instructions. You can exit and resume with operation 3 using these same paths.'
        $answer = Read-PmChoice 'C reload after editing and continue; B save handoff and return to menu; Q cancel' @('c', 'b', 'q')
        if ($answer -eq 'q') { throw [OperationCanceledException]::new('Manual review paused; saved mappings are retained.') }
        if ($answer -eq 'b') { return $false }
    }
}

function Show-PmWizardPlan {
    param($Plan)
    $Plan.Steps | Select-Object Kind, Name, Action, Status | Format-Table -AutoSize | Out-Host
    foreach ($warning in $Plan.Warnings) { Write-Warning $warning }
    foreach ($message in $Plan.BlockingErrors) { Write-Host "BLOCKED: $message" -ForegroundColor Red }
    Write-Host "Journal: $($Plan.JournalPath)"
    Write-PmWizardNote 'Preview reads destination configuration but makes no service writes. Resolve every blocker; reuse is not a content-equivalence guarantee.'
}

function Start-PurviewMigrationWizard {
    [CmdletBinding()]
    param()
    if (-not (Get-Module -ListAvailable ExchangeOnlineManagement | Where-Object { $_.Version -ge [version]'3.9.0' })) {
        throw 'Install ExchangeOnlineManagement 3.9.0 or later before running the wizard. No dependencies are installed automatically.'
    }
    Import-Module ExchangeOnlineManagement -MinimumVersion 3.9.0 -ErrorAction Stop
    Write-PmWizardSection 'Purview configuration migration - guarded preview release'
    Write-PmWizardNote 'Source = read/export tenant. Destination = DIFFERENT tenant to create configuration in.'
    Write-PmWizardNote 'No IRM migration, existing-object updates, content migration, automatic rollback or automatic enforcement.'
    Write-PmWizardNote 'DLP is created disabled; auto-labeling uses simulation. Publishing labels is a separate explicit operation.'
    Write-PmWizardNote 'Display key: cyan = sections; indented dashes = guidance; green = confirmed identity or completed step; yellow = caution; red = failure. Text labels remain meaningful without color.'
    $packagePath = ''
    while ($true) {
        Write-PmWizardSection 'OPERATION MENU (not the solution-selection menu)'
        Write-Host '1 Export source configuration: sign in, select objects, write a new LOCAL package; source is read-only.'
        Write-Host '2 Validate package offline: local hashes/schema only; no sign-in or destination readiness check.'
        Write-Host '3 Preview / import / resume: sign in to destination, review mappings; service writes require confirmation.'
        Write-Host '4 Publish prepared label publishing policies: explicit user-impacting destination writes after review.'
        Write-Host '5 Verify an existing import: sign in to destination; read-back only, no configuration changes.'
        Write-Host 'q Exit (does not disconnect an existing session; disconnect explicitly or close this dedicated pwsh).'
        $choice = Read-PmChoice 'Operation number' @('1', '2', '3', '4', '5', 'q')
        if ($choice -eq 'q') { return }
        try {
            if ($choice -eq '1') {
                Write-PmWizardSection 'EXPORT 1/5 - Source sign-in and identity confirmation'
                $source = Connect-PmWizardTenant 'Source'
                Write-PmWizardSection 'EXPORT 2/5 - SOLUTION SELECTION (4 here means DLP)'
                $types = @('SensitivityLabels', 'AutoLabeling', 'LabelPublishing', 'Dlp', 'SensitiveInformationTypes')
                for ($i = 0; $i -lt $types.Count; $i++) { Write-Host "$($i + 1) $($types[$i])" }
                $indices = @(Read-PmWizardSelection 'Solution numbers' $types.Count)
                $selectedTypes = @($indices | ForEach-Object { $types[$_] })
                $inventory = @(Get-PurviewMigrationInventory -SourceTenantId $source.TenantId -Types $selectedTypes)
                if (-not $inventory.Count) { throw 'No exportable objects were found in the selected solutions. Check roles and source configuration.' }
                Write-PmWizardSection 'EXPORT 3/5 - Select specific objects'
                Write-PmWizardNote 'Rules travel with policies. Supported label dependencies are added automatically. Custom SIT packages are separate: select solution 5 only when you want to export them.'
                $selection = @{}
                foreach ($type in $selectedTypes) {
                    $items = @($inventory | Where-Object { $_.Type -eq $type })
                    if (-not $items.Count) { Write-Host "$type has no objects."; continue }
                    Write-PmWizardSection "$type - available source objects"
                    for ($i = 0; $i -lt $items.Count; $i++) { Write-Host "$($i + 1) $($items[$i].Name) [$($items[$i].SourceId)]" }
                    $selected = @(Read-PmWizardSelection "$type object numbers" $items.Count -AllowSkip)
                    if ($selected.Count) { $selection[$type] = @($selected | ForEach-Object { $items[$_].SourceId }) }
                }
                if (-not $selection.Count) { throw 'No objects selected. Nothing exported. Choose at least one object on your next export.' }
                Write-PmWizardSection 'EXPORT 4/5 - Choose the new local export folder and names'
                $newPath = Read-PmWizardPath -NewExport
                $prefix = Read-PmWizardText 'Optional destination name prefix' 'Example: Migrated-. Enter leaves ordinary names unchanged. This does NOT change label display names; SIT package names start Migrated- by default. Names can be reviewed during import.' -AllowEmpty
                Write-PmWizardSection 'EXPORT REVIEW - selected source policies'
                foreach ($type in $selection.Keys) {
                    foreach ($item in @($inventory | Where-Object { $_.Type -eq $type -and $_.SourceId -in $selection[$type] })) {
                        Write-PmWizardNote "$type policy/object: $($item.Name)"
                    }
                }
                Write-PmWizardNote 'Rules belong to these policies. Referenced label definitions are included by default; their names are not additional DLP policy selections.'
                Write-PmWizardNote 'DLP alert settings are retained when populated. The source ProtectionAlertId response identifier is not copied; no separate alert-migration approval is required. Compare destination Incident reports settings and test alert behavior before activation.'
                $useExistingLabels = $false
                while ($true) {
                    try {
                        $result = Export-PurviewMigrationPackage -SourceTenantId $source.TenantId -Selection $selection -Path $newPath -NamePrefix $prefix -UseExistingDlpLabels:$useExistingLabels
                        break
                    } catch {
                        $failure = $_.Exception
                        $filesystemFailure = $null
                        while ($true) {
                            if ($failure -is [IO.IOException] -or $failure -is [UnauthorizedAccessException]) { $filesystemFailure = $failure }
                            if ($failure.Data.Contains('ExistingDlpLabelsOptInAvailable') -or -not $failure.InnerException) { break }
                            $failure = $failure.InnerException
                        }
                        if (-not $useExistingLabels -and $failure.Data['ExistingDlpLabelsOptInAvailable'] -eq $true) {
                            Write-PmWizardSection 'DLP LABEL DEPENDENCIES - existing labels or label migration'
                            Write-Warning "$($failure.Data['ExistingDlpLabelCount']) referenced label definition(s) contain unsupported settings. These are dependencies of your selected DLP rules, not additional DLP policies."
                            Write-PmWizardNote 'The default path exports label configuration too. Encryption, site/group protection and unknown settings cannot be silently removed or copied as tenant-independent values.'
                            Write-PmWizardNote 'If the required labels ALREADY EXIST in the destination (or you will prepare them separately before import), choose Y to export identity references only. The wizard will require you to select and review each destination label. No label settings are exported, created or updated on that path.'
                            Write-PmWizardNote 'Choose N to keep full label-configuration migration required and stop. Unsupported label settings must then be supported before export can proceed. Other DLP blockers are not waived by choosing Y.'
                            if ((Read-PmChoice 'Use existing destination labels instead of migrating label configuration? (y/n; Q cancels)' @('y', 'n')) -ne 'y') {
                                throw [OperationCanceledException]::new('Label configuration migration remains required. No package was created; unsupported label settings still need support.')
                            }
                            $useExistingLabels = $true
                        } elseif ($filesystemFailure) {
                            Write-Warning "Export filesystem failure: $($filesystemFailure.Message)"
                            Write-PmWizardNote 'No successful export is assumed. Any partial folder is retained; choose a different NEW folder or Q to cancel. Selections are retained.'
                            $newPath = Read-PmWizardPath -NewExport
                        } else { throw }
                    }
                }
                $packagePath = $result.Path
                Write-PmWizardSection 'EXPORT 5/5 - Package created and validated'
                Write-Host 'Local package validation passed. This is not destination import or alert verification.' -ForegroundColor Green
                $result | Format-List | Out-Host
                Get-Content -LiteralPath $result.NextSteps | Out-Host
                if ($selection.ContainsKey('Dlp') -and -not $selection.ContainsKey('SensitiveInformationTypes')) {
                    Write-PmWizardNote 'DLP custom SIT packages were not included. If the destination already has the required custom SITs, keep them and map classifier references to their validated destination entity IDs. If they are missing, run a separate export: choose operation 1, select solution 5 only, then import that package before this DLP package.'
                }
                Write-PmWizardNote 'Disconnect before choosing a destination account. A fresh pwsh process is safest if SSO/session isolation is unclear.'
                if ((Read-PmChoice 'Disconnect source now? (y/n; Q returns to menu)' @('y', 'n')) -eq 'y') {
                    Disconnect-PurviewMigrationTenant -Confirm:$false
                    Write-Host 'Source disconnected and compliance-session removal verified.' -ForegroundColor Green
                }
                Write-PmWizardSection 'NEXT STEPS - destination handoff'
                Write-PmWizardNote 'Next: operation 3, open this package, sign in to the destination and follow guided mappings. No tenant ID lookup is needed.'
                continue
            }
            Write-PmWizardSection 'PACKAGE 1 - Open an existing export; validation never modifies its hashed source files.'
            $packagePath = Read-PmWizardPath -Default $packagePath
            if ($choice -eq '2') {
                Test-PurviewMigrationPackage -Path $packagePath | Format-List | Out-Host
                Write-PmWizardNote 'Hashes/schema checked locally only; no destination preflight performed. Next: operation 3 to review a destination.'
                continue
            }
            $package = Read-PmPackage $packagePath
            Write-PmWizardSection 'DESTINATION 2 - Choose destination instructions and confirm sign-in'
            $mappingPath = Read-PmWizardPath -File -Default (Join-Path $packagePath 'mappings.json')
            if (@('objects.json', 'manifest.json', 'last-preview.json') -contains [IO.Path]::GetFileName($mappingPath)) { throw 'Choose mappings.json (or your separate mappings file), not a source definition or preview.' }
            $destination = Connect-PmWizardTenant 'Destination' -ExcludedTenantId $package.Manifest.SourceTenantId
            if ($choice -eq '5') {
                $mappings = Read-PmMappings $package $mappingPath
                if ($mappings.DestinationTenantId -ne $destination.TenantId) { throw 'Mappings target a different destination.' }
                Test-PurviewMigrationImport -Path $packagePath -MappingsPath $mappingPath | Format-Table -AutoSize | Out-Host
                Write-PmWizardNote 'Read-back finished. Review each status; reused existence does not establish semantic equivalence or workload distribution.'
                continue
            }
            Write-PmWizardSection 'DESTINATION 3 - Review mappings (local instructions only; no service writes)'
            if (-not (Edit-PmWizardMappings $package $mappingPath $destination)) { continue }
            $publish = $choice -eq '4'
            Write-PmWizardSection 'DESTINATION 4 - Online preflight and saved preview'
            $plan = New-PurviewMigrationPlan -Path $packagePath -MappingsPath $mappingPath -PublishLabels:$publish
            Show-PmWizardPlan $plan
            if (-not $plan.CanImport) { Write-Host "Correct blockers in $mappingPath BEFORE first import, then choose operation 3 again. If a journal exists, restore original mappings rather than editing them."; continue }
            $previewPath = Join-Path $packagePath 'last-preview.json'
            Write-PmJson $previewPath $plan
            Write-PmWizardNote "Exact parameters/preview: $previewPath. Inspect scopes, dependencies, names and manual reviews before proceeding."
            if ($publish) { Write-Warning 'Publication exposes labels and default/mandatory policy settings to destination users; it is NOT inactive staging. Other pending mapped objects can also be created by this plan.' }
            Write-PmWizardSection 'DESTINATION 5 - Explicit write authorization'
            Write-Host "Destination account: $($destination.UserPrincipalName); tenant: $($destination.TenantId). Source: $($package.Manifest.SourceTenantId)."
            Write-Warning 'No automatic rollback. DLP remains disabled; auto-labeling remains in simulation. Declining makes NO service writes.'
            if ((Read-PmChoice 'Execute this reviewed plan? (y/n; Q cancels)' @('y', 'n')) -eq 'n') { continue }
            $phrase = if ($publish) { 'PUBLISH' } else { 'IMPORT' }
            $confirmation = Read-PmWizardText "Type $phrase to authorize destination writes" 'Any other text cancels execution; the discovered destination GUID is passed internally.'
            if ($confirmation -cne $phrase) { Write-Warning 'Confirmation did not match. No service writes performed.'; continue }
            Import-PurviewMigrationPackage -Path $packagePath -MappingsPath $mappingPath `
                -DestinationTenantId $destination.TenantId -ConfirmDestinationTenantId $destination.TenantId `
                -PublishLabels:$publish -Confirm:$false | Format-List | Out-Host
            Write-PmWizardSection 'RESULT - review status and remaining work'
            Write-PmWizardNote 'ConfigurationVerifiedManualAlertReviewRequired applies to legacy staged packages and retains their review requirement. Compare destination alert settings and test behavior; a separate alert policy is not assumed necessary.'
            Write-PmWizardNote 'Review the returned status and journal. VerifiedWithDeferredPublication means publication is pending; ConfigurationVerifiedManualPublishingOrderRequired still requires an ordering check.'
            Write-PmWizardNote 'ConfigurationVerifiedReusedLabelsNotContentVerified means existing destination labels were used; their configuration was not migrated or certified equivalent. Review ExistingLabelReferences even when the batch also has pending alert work.'
            Write-PmWizardNote 'Next: operation 5 for read-back. Validate workload behavior before manual activation. Operation 4 is separate explicit publication.'
        } catch [OperationCanceledException] {
            Write-Host "$($_.Exception.Message) Returning to operation menu; previously saved package/mappings/journal are retained." -ForegroundColor Yellow
        } catch {
            Write-PmWizardSection 'OPERATION STOPPED - review the blockers below'
            Write-Host "Operation failed: $($_.Exception.Message)" -ForegroundColor Red
            if ($choice -eq '1') {
                Write-PmWizardNote 'Export reads source configuration only; this operation has not imported or changed tenant configuration.'
                Write-PmWizardNote 'A DLP-only export reads selected DLP policies/rules and supported label dependencies; custom SIT packages are read only when explicitly selected.'
                Write-PmWizardSection 'Diagnostics - script locations only (no policy payloads or credentials)'
                Write-Host $_.ScriptStackTrace
                Write-PmWizardNote 'Retain any partial export folder for inspection; do not treat it as successful or edit hashes. Report the source-read error and stack so the returned shape can be checked without skipping objects.'
                continue
            }
            Write-PmWizardNote 'No success is assumed. Check roles, original package, mappings and journal LastError. Never delete a journal to bypass an ambiguous Creating state.'
            Write-PmWizardNote 'If tenant isolation is unclear, close this dedicated pwsh and resume in a fresh process. See docs\CUSTOMER-GUIDE.md for recovery.'
        }
    }
}
