function Read-PmRuleXml {
    [CmdletBinding(DefaultParameterSetName = 'Text')]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'Text')][string]$Xml,
        [Parameter(Mandatory, ParameterSetName = 'Bytes')][byte[]]$Bytes
    )
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.MaxCharactersInDocument = 10MB
    $inputStream = if ($PSCmdlet.ParameterSetName -eq 'Bytes') {
        [IO.MemoryStream]::new($Bytes)
    } else {
        [IO.StringReader]::new($Xml)
    }
    $reader = $null
    try {
        $reader = [Xml.XmlReader]::Create($inputStream, $settings)
        $document = [Xml.XmlDocument]::new()
        $document.XmlResolver = $null
        $document.PreserveWhitespace = $true
        $document.Load($reader)
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        $inputStream.Dispose()
    }
    if ($document.DocumentElement.LocalName -ne 'RulePackage') { throw 'Expected a RulePackage XML document.' }
    $pack = $document.SelectSingleNode("/*[local-name()='RulePackage']/*[local-name()='RulePack']")
    if ($null -eq $pack -or -not $pack.GetAttribute('id')) { throw 'SIT XML has no RulePack id.' }
    $packageId = [guid]::Empty
    if (-not [guid]::TryParse($pack.GetAttribute('id'), [ref]$packageId) -or $packageId -eq [guid]::Empty) {
        throw 'SIT XML RulePack id must be a nonempty GUID.'
    }
    if ($document.SelectNodes("//*[local-name()='Fingerprint' or local-name()='EDM']").Count) {
        throw 'Fingerprint and EDM classifier packages are outside the conventional SIT scope.'
    }
    return ,$document
}

function Get-PmSitPackageNames {
    param($Data)
    foreach ($field in @('Name', 'RuleCollectionName', 'LocalizedName')) {
        if ($Data[$field] -is [string] -and -not [string]::IsNullOrWhiteSpace($Data[$field])) {
            [string]$Data[$field]
        }
    }
}

function Get-PmSitStructureSummary {
    param([Xml.XmlDocument]$Document, [Collections.IDictionary]$Data, [int]$EntityCount)
    $rules = @($Document.SelectNodes("/*/*[local-name()='Rules']"))
    $ruleChildren = @(
        foreach ($ruleSet in $rules) {
            foreach ($child in $ruleSet.ChildNodes | Where-Object { $_ -is [Xml.XmlElement] }) {
                [pscustomobject]@{ Name = $child.LocalName }
            }
        }
    )
    $shape = if ($ruleChildren.Count) {
        ($ruleChildren | Group-Object Name | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', '
    } else {
        'none'
    }
    $flags = @(
        foreach ($field in @('IsAIPoweredRuleCollection', 'IsEncrypted', 'IsExportable', 'IsFingerprintRuleCollection', 'IsValid')) {
            if ($Data.Contains($field) -and $Data[$field] -is [bool]) { "$field=$($Data[$field])" }
        }
    )
    $flagSummary = if ($flags.Count) { "; flags: $($flags -join ', ')" } else { '' }
    "Unsupported SIT XML structure: $EntityCount Entity elements; root=$($Document.DocumentElement.LocalName); namespace=$($Document.DocumentElement.NamespaceURI); Rules children=$shape$flagSummary."
}

function Get-PmSitReadIdentity {
    param($Data)
    $identities = @(Get-PmIdentityValues $Data)
    if ($identities.Count) { return $identities[0] }
    foreach ($field in @('RuleCollectionName', 'Name', 'LocalizedName')) {
        if ($Data[$field] -is [string] -and -not [string]::IsNullOrWhiteSpace($Data[$field])) {
            return [string]$Data[$field]
        }
    }
    $xml = $Data['ClassificationRuleCollectionXml']
    if ($xml -is [string] -and -not [string]::IsNullOrWhiteSpace($xml)) {
        $document = Read-PmRuleXml $xml
        return $document.SelectSingleNode("/*/*[local-name()='RulePack']").GetAttribute('id')
    }
    throw 'SIT summary has no usable identity, RuleCollectionName, Name, LocalizedName or classification XML. Cannot retrieve the full rule package safely.'
}

function ConvertTo-PmSitRecord {
    param($Definition)
    @{
        Name = $Definition.Name
        Identity = $Definition.SourceId
        Guid = $Definition.SourceId
        SerializedClassificationRuleCollection = $Definition.XmlBytes
    }
}

function Get-PmSitDefinition {
    param($Raw)
    $data = ConvertTo-PmData $Raw
    $bytes = $data['SerializedClassificationRuleCollection']
    if ($bytes -isnot [byte[]]) {
        if ($bytes -is [array]) { $bytes = [byte[]]$bytes }
        else { throw "SIT package '$($data.Name)' did not return XML bytes. Retrieve the full package with -Identity." }
    }
    $document = Read-PmRuleXml -Bytes $bytes
    $xml = $document.OuterXml
    $pack = $document.SelectSingleNode("/*/*[local-name()='RulePack']")
    $id = $pack.GetAttribute('id')
    $details = $pack.SelectSingleNode("./*[local-name()='Details']")
    $xmlNames = @()
    if ($null -ne $details) {
        $defaultLanguage = $details.GetAttribute('defaultLangCode')
        $localized = @($details.SelectNodes("./*[local-name()='LocalizedDetails']") |
            Sort-Object @{ Expression = { if ($_.GetAttribute('langcode') -eq $defaultLanguage) { 0 } else { 1 } } })
        $xmlNames = @($localized | ForEach-Object {
            $_.SelectNodes("./*[local-name()='Name']") | ForEach-Object { $_.InnerText }
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    $names = @(@(Get-PmSitPackageNames $data) + $xmlNames | Select-Object -Unique)
    if (-not $names.Count) { throw "SIT package '$id' has no usable package name in its metadata or XML." }
    $name = [string]$names[0]
    $entities = @($document.SelectNodes("/*/*[local-name()='Rules']/*[local-name()='Entity']"))
    $unsupported = @()
    if (-not $entities.Count) {
        $unsupported = @(Get-PmSitStructureSummary $document $data $entities.Count)
    }
    $localIds = @($document.SelectNodes('//*[@id]') | ForEach-Object { $_.GetAttribute('id') })
    $external = @($document.SelectNodes('//*[@idRef]') | ForEach-Object {
        $reference = $_.GetAttribute('idRef')
        if ($reference -notin $localIds) { $reference }
    } | Select-Object -Unique)
    $entityAliases = @{}
    foreach ($entity in $entities) { $entityAliases[$entity.GetAttribute('id')] = $entity.GetAttribute('id') }
    foreach ($resource in $document.SelectNodes("//*[local-name()='LocalizedStrings']/*[local-name()='Resource']")) {
        $entityId = $resource.GetAttribute('idRef')
        if ($entityId -notin @($entities | ForEach-Object { $_.GetAttribute('id') })) { continue }
        foreach ($name in $resource.SelectNodes("*[local-name()='Name']")) {
            if ($entityAliases.ContainsKey($name.InnerText) -and $entityAliases[$name.InnerText] -ne $entityId) {
                throw "Ambiguous localized SIT name '$($name.InnerText)'; resolve it in the source package."
            }
            $entityAliases[$name.InnerText] = $entityId
        }
    }
    $aliases = @(@($id) + $names + @($entityAliases.Keys))
    if ($unsupported.Count) {
        $aliases += $localIds
        $aliases += @($document.SelectNodes("//*[local-name()='LocalizedStrings']//*[local-name()='Name']") |
            ForEach-Object { $_.InnerText } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    @{
        Key = "SensitiveInformationTypes:$id"; Kind = 'SensitiveInformationTypes'
        SourceId = $id; Name = $name
        Aliases = @($aliases | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
        EntityIds = @($entities | ForEach-Object { $_.GetAttribute('id') })
        EntityAliases = $entityAliases
        ParentKey = ''; Fields = @{}; Dependencies = @(); Selected = $false
        ExternalReferences = $external; XmlContent = $xml; XmlBytes = $bytes; XmlFile = ''
        UnsupportedFields = $unsupported
        UnresolvedReferences = @()
    }
}

function New-PmDestinationXml {
    param($Definition, [string]$Xml, $Mapping)
    $document = Read-PmRuleXml $Xml
    $pack = $document.SelectSingleNode("/*/*[local-name()='RulePack']")
    $destinationId = [guid]$Mapping.DestinationId
    if ($destinationId -eq [guid]::Empty -or $destinationId -eq [guid]$Definition.SourceId) {
        throw 'A SIT package must have a new, nonempty destination package GUID.'
    }
    $pack.SetAttribute('id', $destinationId.ToString())
    if ($document.FirstChild -is [Xml.XmlDeclaration]) { $document.FirstChild.Encoding = 'utf-8' }
    foreach ($node in $pack.SelectNodes(".//*[local-name()='LocalizedDetails']/*[local-name()='Name']")) {
        $node.InnerText = [string]$Mapping.Name
    }
    $document.OuterXml
}

function Get-PmPreparedSitXml {
    param($Package, $Definition, $Mapping, $Mappings)
    $sourceDocument = Read-PmRuleXml -Bytes ([IO.File]::ReadAllBytes((Join-Path $Package.Root $Definition.XmlFile)))
    $xml = New-PmDestinationXml $Definition $sourceDocument.OuterXml $Mapping
    $document = Read-PmRuleXml $xml
    foreach ($attribute in $document.SelectNodes('//@idRef')) {
        if ($Mappings.References.ContainsKey($attribute.Value)) {
            $entry = $Mappings.References[$attribute.Value]
            if ($entry.Reviewed -eq $true -and $entry.Value) { $attribute.Value = [string]$entry.Value }
        }
    }
    $document.OuterXml
}

function Get-PmXmlSignature {
    param([Xml.XmlElement]$Element)
    $attributes = @{}
    foreach ($attribute in $Element.Attributes) {
        if ($attribute.NamespaceURI -ne 'http://www.w3.org/2000/xmlns/') {
            $attributes["$($attribute.NamespaceURI):$($attribute.LocalName)"] = $attribute.Value
        }
    }
    $children = @()
    $hasElements = @($Element.ChildNodes | Where-Object { $_ -is [Xml.XmlElement] }).Count -gt 0
    foreach ($node in $Element.ChildNodes) {
        if ($node -is [Xml.XmlElement]) { $children += Get-PmXmlSignature $node }
        elseif ($node.NodeType -ne [Xml.XmlNodeType]::Comment -and -not ($hasElements -and [string]::IsNullOrWhiteSpace($node.Value))) {
            $children += [string]$node.Value
        }
    }
    @{ Element = "$($Element.NamespaceURI):$($Element.LocalName)"; Attributes = $attributes; Children = @($children) }
}

function Assert-PmSitReadBack {
    param($Actual, [string]$ExpectedXml, [string]$Name)
    $actualDefinition = Get-PmSitDefinition ([pscustomobject]$Actual)
    $actualDocument = Read-PmRuleXml $actualDefinition.XmlContent
    $expectedDocument = Read-PmRuleXml $ExpectedXml
    $actualSignature = Get-PmCanonicalJson (Get-PmXmlSignature $actualDocument.DocumentElement)
    $expectedSignature = Get-PmCanonicalJson (Get-PmXmlSignature $expectedDocument.DocumentElement)
    if ($actualSignature -ne $expectedSignature) {
        throw "SIT XML read-back differs for '$Name'; manual verification is required."
    }
}
