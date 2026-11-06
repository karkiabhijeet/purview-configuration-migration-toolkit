$script:PmVersion = '0.1.0'
$script:PmMetadata = @(
    'Identity', 'Guid', 'ImmutableId', 'Id', 'DistinguishedName', 'ObjectState',
    'WhenCreated', 'WhenCreatedUTC', 'WhenChanged', 'WhenChangedUTC', 'ExchangeVersion',
    'OrganizationId', 'OriginatingServer', 'IsValid', 'RunspaceId', 'PSComputerName',
    'PSShowComputerName', 'ObjectVersion', 'Workload', 'DistributionStatus',
    'DistributionResults', 'LastStatusUpdateTime', 'LastStatusUpdateTimeUTC',
    'PolicyDistributionStatus', 'PolicyDistributionResults', 'ModificationTimeUtc',
    'CreationTimeUtc', 'CreatedBy', 'LastModifiedBy', 'ReadOnly',
    'Rules', 'RuleCount', 'ExecutionStatus', 'ExecutionStatusDetails',
    'ExchangeObjectId', 'AdminDisplayName', 'PolicyVersion', 'RuleVersion',
    'Mode', 'Status', 'Enabled', 'SerializedClassificationRuleCollection'
)

function Assert-PmCommand {
    param([string]$Name, [string[]]$Parameters = @())
    $command = Get-Command -Name $Name -ErrorAction Stop
    foreach ($parameter in $Parameters) {
        if (-not $command.Parameters.ContainsKey($parameter)) {
            throw "$Name does not expose -$parameter. Check module version and Purview RBAC permissions."
        }
    }
    $validSets = @($command.ParameterSets | Where-Object {
        @($_.Parameters | Where-Object { $_.IsMandatory -and $_.Name -notin $Parameters }).Count -eq 0
    })
    if (-not $validSets.Count) {
        throw "$Name is missing mandatory parameters for every available parameter set. Check the exported definition and RBAC; no interactive parameter prompting is allowed."
    }
    $command
}

function Invoke-PmCommand {
    param([string]$Name, [System.Collections.IDictionary]$Parameters = @{})
    $null = Assert-PmCommand $Name @($Parameters.Keys)
    & $Name @Parameters -ErrorAction Stop
}

function Get-PurviewMigrationSession {
    [CmdletBinding()]
    param([string]$ExpectedTenantId)
    $null = Assert-PmCommand 'Get-ConnectionInformation'
    $connections = @(Get-ConnectionInformation -ErrorAction Stop | Where-Object {
        $_.State -eq 'Connected' -and $_.IsEopSession -eq $true
    })
    if ($connections.Count -ne 1) {
        throw "Expected exactly one connected Security & Compliance REST session; found $($connections.Count). Disconnect competing sessions or use a fresh pwsh process."
    }
    $connection = $connections[0]
    $tenant = [guid]::Empty
    if (-not [guid]::TryParse([string]$connection.TenantID, [ref]$tenant) -or $tenant -eq [guid]::Empty) {
        throw 'The connected session did not provide a trustworthy TenantID. Reconnect in a fresh pwsh process.'
    }
    if ([string]$connection.TokenStatus -ne 'Active') {
        throw 'The compliance session token is not active. Reconnect before continuing.'
    }
    if ($connection.ModulePrefix) {
        throw 'Prefixed compliance connections are not supported. Use an unprefixed session in a fresh pwsh process.'
    }
    if ($ExpectedTenantId -and $tenant -ne [guid]$ExpectedTenantId) {
        throw "Wrong tenant: expected $ExpectedTenantId, connected to $tenant."
    }
    [pscustomobject]@{
        TenantId = $tenant.ToString()
        UserPrincipalName = [string]$connection.UserPrincipalName
        ConnectionId = [string]$connection.ConnectionId
    }
}

function Connect-PurviewMigrationTenant {
    [CmdletBinding()]
    param([guid]$TenantId, [string]$UserPrincipalName)
    Import-Module ExchangeOnlineManagement -MinimumVersion 3.9.0 -ErrorAction Stop
    $active = @(Get-ConnectionInformation -ErrorAction Stop | Where-Object { $_.State -eq 'Connected' -and $_.IsEopSession -eq $true })
    if ($active.Count) { throw 'A compliance session already exists. Disconnect it explicitly before changing tenants.' }
    $connectionParameters = @{ EnableSearchOnlySession = $false; ErrorAction = 'Stop' }
    if ($UserPrincipalName) { $connectionParameters.UserPrincipalName = $UserPrincipalName }
    Connect-IPPSSession @connectionParameters
    $validation = @{}
    if ($PSBoundParameters.ContainsKey('TenantId')) { $validation.ExpectedTenantId = $TenantId.ToString() }
    Get-PurviewMigrationSession @validation
}

function Disconnect-PurviewMigrationTenant {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $session = Get-PurviewMigrationSession
    if ($PSCmdlet.ShouldProcess($session.TenantId, 'Disconnect Security & Compliance session')) {
        $null = Assert-PmCommand 'Disconnect-ExchangeOnline' @('ConnectionId')
        Disconnect-ExchangeOnline -ConnectionId $session.ConnectionId -Confirm:$false -ErrorAction Stop
        $remaining = @(Get-ConnectionInformation -ErrorAction Stop | Where-Object { $_.State -eq 'Connected' -and $_.IsEopSession -eq $true })
        if ($remaining.Count) { throw 'Compliance connections remain. Use a fresh pwsh process for the destination.' }
    }
}

function ConvertTo-PmData {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value -is [bool] -or $Value -is [ValueType]) {
        if ($Value -is [guid] -or $Value -is [datetime] -or $Value.GetType().IsEnum) { return [string]$Value }
        return $Value
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $Value.Keys) { $result[[string]$key] = ConvertTo-PmData $Value[$key] }
        return $result
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $result = @($Value | ForEach-Object { ConvertTo-PmData $_ })
        return ,$result
    }
    $result = @{}
    foreach ($property in $Value.PSObject.Properties) {
        if ($property.IsGettable) { $result[$property.Name] = ConvertTo-PmData $property.Value }
    }
    return $result
}

function Test-PmMeaningful {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [string]) { return -not [string]::IsNullOrWhiteSpace($Value) }
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [System.Collections.ICollection]) { return $Value.Count -gt 0 }
    return $Value -ne 0
}

function ConvertFrom-PmJsonField {
    param($Value)
    if ($Value -is [string] -and $Value.TrimStart() -match '^[\[{]') {
        try {
            $options = [System.Text.Json.JsonDocumentOptions]::new()
            $options.MaxDepth = 100
            $jsonDocument = [System.Text.Json.JsonDocument]::Parse($Value, $options)
            $jsonDocument.Dispose()
        } catch [System.Text.Json.JsonException] {
            # Nested marking text and regex literals can begin with "[" without being JSON.
            return $Value
        }
        return ConvertFrom-Json -InputObject $Value -AsHashtable -Depth 100 -ErrorAction Stop
    }
    return $Value
}

function Get-PmLeaves {
    param([AllowNull()]$Value)
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) { Get-PmLeaves $Value[$key] }
    } elseif ($Value -is [string]) {
        $parsed = ConvertFrom-PmJsonField $Value
        if ($parsed -is [string]) { $Value } else { Get-PmLeaves $parsed }
    } elseif ($Value -is [System.Collections.IEnumerable]) {
        foreach ($item in $Value) { Get-PmLeaves $item }
    }
}

function Get-PmCanonicalJson {
    param([AllowNull()]$Value)
    function Sort-PmValue {
        param($InputValue)
        if ($InputValue -is [string]) {
            $parsed = ConvertFrom-PmJsonField $InputValue
            if ($parsed -isnot [string]) { return Sort-PmValue $parsed }
        }
        if ($InputValue -is [System.Collections.IDictionary]) {
            $ordered = [ordered]@{}
            foreach ($key in @($InputValue.Keys | Sort-Object)) { $ordered[$key] = Sort-PmValue $InputValue[$key] }
            return $ordered
        }
        if ($InputValue -is [array]) { return ,@($InputValue | ForEach-Object { Sort-PmValue $_ }) }
        return $InputValue
    }
    ConvertTo-Json -InputObject (Sort-PmValue $Value) -Depth 100 -Compress
}

function Write-PmJson {
    param([string]$Path, $Value)
    $json = ConvertTo-Json -InputObject $Value -Depth 100
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $Path -Force -ErrorAction Stop
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -ErrorAction Stop }
    }
}

function Read-PmJson {
    param([string]$Path)
    ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path)) -AsHashtable -Depth 100 -ErrorAction Stop
}

function Get-PmIdentityValue {
    param([AllowNull()]$Value, [int]$Depth = 0)
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Depth -ge 8) { throw 'Identity nesting exceeds the supported depth; cannot safely resolve the object identity.' }
        foreach ($field in @('Guid', 'ImmutableId', 'Identity', 'Id')) {
            Get-PmIdentityValue $Value[$field] ($Depth + 1)
        }
    } elseif (($Value -is [string] -or $Value -is [ValueType]) -and (Test-PmMeaningful $Value)) {
        $identity = [string]$Value
        $guid = [guid]::Empty
        if (-not [guid]::TryParse($identity, [ref]$guid) -or $guid -ne [guid]::Empty) {
            $identity
        }
    }
}

function Get-PmIdentityValues {
    param($Object)
    if ($Object -isnot [System.Collections.IDictionary]) {
        throw 'Expected an object record with identity fields, not an empty result, scalar or collection.'
    }
    foreach ($field in @('Guid', 'ImmutableId', 'Identity', 'Id')) {
        Get-PmIdentityValue $Object[$field]
    }
}

function Get-PmObjectId {
    param($Object)
    $identities = @(Get-PmIdentityValues $Object)
    if ($identities.Count) { return $identities[0] }
    throw "Object '$($Object['Name'])' has no stable identity. Expected a nonempty Guid, ImmutableId, Identity or Id. Returned property names: $(@($Object.Keys | Sort-Object) -join ', ')."
}

function Test-PmEmptyStructure {
    # True only for values that structurally carry nothing: null/blank text, '[]'/'{}' JSON, empty
    # collections, or records whose every value is itself empty. Numbers, booleans and text never qualify.
    param([AllowNull()]$Value, [int]$Depth = 0)
    if ($Depth -gt 8) { return $false }
    if ($null -eq $Value) { return $true }
    if ($Value -is [string]) {
        $text = $Value.Trim()
        return $text -eq '' -or $text -eq '[]' -or $text -eq '{}'
    }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) { if (-not (Test-PmEmptyStructure $Value[$key] ($Depth + 1))) { return $false } }
        return $true
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($item in $Value) { if (-not (Test-PmEmptyStructure $item ($Depth + 1))) { return $false } }
        return $true
    }
    return $false
}

function Test-PmEmptyProtectionAlertDependency {
    param([AllowNull()]$Value)
    if ($Value -isnot [Collections.IDictionary] -or $Value.Count -ne 1 -or
        -not $Value.Contains('ProtectionAlertId')) { return $false }
    $alertId = [guid]::Empty
    return ($Value['ProtectionAlertId'] -is [string] -or $Value['ProtectionAlertId'] -is [guid]) -and
        [guid]::TryParse([string]$Value['ProtectionAlertId'], [ref]$alertId) -and $alertId -eq [guid]::Empty
}

function Get-PmProtectionAlertReference {
    # Returns the lowercase GUID only for exactly @{ ProtectionAlertId = <valid nonempty GUID> }.
    param([AllowNull()]$Value)
    if ($Value -isnot [Collections.IDictionary] -or $Value.Count -ne 1 -or
        -not $Value.Contains('ProtectionAlertId')) { return $null }
    $reference = $Value['ProtectionAlertId']
    $alertId = [guid]::Empty
    if (($reference -is [string] -or $reference -is [guid]) -and
        [guid]::TryParse([string]$reference, [ref]$alertId) -and $alertId -ne [guid]::Empty) {
        return $alertId.ToString()
    }
    return $null
}

function Get-PmDefinition {
    param([string]$Kind, $Raw, [string]$ParentKey = '', [switch]$AllowUnsupported, [switch]$AllowDlpAlertReview)
    $spec = $script:PmSpecifications[$Kind]
    $data = ConvertTo-PmData $Raw
    $id = Get-PmObjectId $data
    if (-not $data['Name']) { throw "$Kind object $id has no Name." }
    $fields = @{}
    $unsupported = @()
    $alertReview = $null
    foreach ($field in $data.Keys) {
        if ($Kind -eq 'Dlp' -and (Test-PmDlpDefaultField $field $data[$field])) { continue }
        if ($Kind -eq 'DlpRule' -and $field -eq 'IsAdvancedRule') {
            if ($data[$field] -is [bool] -and
                $data[$field] -eq (Test-PmMeaningful $data['AdvancedRule'])) { continue }
            if ($null -ne $data[$field]) { $unsupported += $field; continue }
        }
        if ($Kind -eq 'DlpRule' -and $field -eq 'ExternalScenarioDependancies') {
            if (-not (Test-PmEmptyStructure $data[$field]) -and
                -not (Test-PmEmptyProtectionAlertDependency $data[$field])) {
                $alertId = Get-PmProtectionAlertReference $data[$field]
                if ($alertId) {
                    # Preserve the explicit legacy package contract; default exports exclude response-only IDs.
                    if ($AllowDlpAlertReview) {
                        $alertReview = @{
                            Kind = 'DlpProtectionAlert'; Status = 'ManualAlertReviewPending'; Creatable = $false
                            SourceReferenceSha256 = (Get-PmTextHash $alertId)
                        }
                    }
                } else {
                    $unsupported += $field
                }
            }
            continue
        }
        if ($field -in @($spec.Fields + $spec.SetOnly)) {
            if ($field -eq 'ParentId' -and [string]$data[$field] -eq [guid]::Empty.ToString()) { continue }
            if ($field -eq 'AdvancedRule' -and (Test-PmMeaningful $data[$field])) {
                if ($data[$field] -isnot [string]) { throw "AdvancedRule for '$($data.Name)' must be a JSON string." }
                $null = ConvertFrom-Json -InputObject $data[$field] -AsHashtable -Depth 100 -ErrorAction Stop
            }
            if ($null -ne $data[$field] -and -not ($data[$field] -is [string] -and $data[$field] -eq '')) {
                $fields[$field] = $data[$field]
            }
        } elseif ($field -notin @($script:PmMetadata + $spec.Ignored) -and (Test-PmMeaningful $data[$field])) {
            $unsupported += $field
        }
    }
    if ($unsupported.Count -and -not $AllowUnsupported) {
        throw "$Kind '$($data.Name)' has unsupported populated fields: $($unsupported -join ', '). No incomplete export will be certified."
    }

    $definition = @{
        Key = "${Kind}:$id"; Kind = $Kind; SourceId = $id; Name = [string]$data.Name
        Aliases = @(@($id) + @(Get-PmIdentityValues $data) + @($data.Name) | Where-Object { $_ } | Select-Object -Unique)
        ParentKey = $ParentKey; Fields = $fields; Dependencies = @()
        ExternalReferences = @(); Selected = $false
        UnsupportedFields = @($unsupported)
        UnresolvedReferences = @()
    }
    if ($alertReview) { $definition.AlertReview = $alertReview }
    $definition
}

function Get-PmUnsupportedFieldShapes {
    param($Definition, $Raw)
    $data = ConvertTo-PmData $Raw
    foreach ($field in $Definition.UnsupportedFields) {
        $value = $data[$field]
        $shape = if ($null -eq $value) { 'null' }
            elseif ($value -is [string]) { "string length=$($value.Length)" }
            elseif ($value -is [Collections.IDictionary]) { "record property count=$($value.Count)" }
            elseif ($value -is [Collections.ICollection]) { "collection count=$($value.Count)" }
            else { "scalar type=$($value.GetType().FullName)" }
        if ($Definition.Kind -eq 'DlpRule' -and $field -eq 'ExternalScenarioDependancies' -and
            $value -is [Collections.IDictionary] -and $value.Contains('ProtectionAlertId')) {
            $alertId = [guid]::Empty
            $isGuid = [guid]::TryParse([string]$value['ProtectionAlertId'], [ref]$alertId)
            $shape += "; ProtectionAlertId valid GUID=$isGuid"
            if ($isGuid) { $shape += "; empty GUID=$($alertId -eq [guid]::Empty)" }
            if ($isGuid -and $alertId -ne [guid]::Empty) {
                $shape += '; additional or unknown dependency structure remains unsupported; only an exact single ProtectionAlertId GUID record is excluded as response metadata'
            }
        }
        "${field}: $shape"
    }
}
