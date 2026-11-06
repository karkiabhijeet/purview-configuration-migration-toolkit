#Requires -Version 7.4
<#
.SYNOPSIS
Read-only structural diagnostic for DLP rule ExternalScenarioDependancies.

.DESCRIPTION
Run inside an ALREADY connected Security & Compliance session (this script never signs in,
imports, or writes). For each named policy it reads that policy's rules only and prints,
per rule, the rule's parent association and a recursive structure summary of
ExternalScenarioDependancies: .NET type names, property/key names, collection counts and
string lengths. It never prints string, number or boolean values, regexes, or the rule payload.
Share the output when ExternalScenarioDependancies blocks an export.

.EXAMPLE
.\Tools\Get-DlpRuleDependencyShape.ps1 -Policy 'My DLP policy'
.\Tools\Get-DlpRuleDependencyShape.ps1 -Policy 'My DLP policy' | ConvertTo-Json -Depth 20
#>
[CmdletBinding()]
param([Parameter(Mandatory, Position = 0)][string[]]$Policy)

function Get-DlpField {
    param($Object, [string]$Name)
    if ($Object -is [System.Collections.IDictionary]) {
        return [pscustomobject]@{ Has = $Object.Contains($Name); Value = $Object[$Name] }
    }
    $property = $Object.PSObject.Properties[$Name]
    [pscustomobject]@{ Has = [bool]$property; Value = if ($property) { $property.Value } else { $null } }
}

function Get-DlpShapeNode {
    param([AllowNull()]$Value, [int]$Depth = 0)
    if ($null -eq $Value) { return [ordered]@{ Kind = 'null'; Empty = $true } }
    $guid = [guid]::Empty
    if ($Value -is [guid] -or ($Value -is [string] -and [guid]::TryParse($Value, [ref]$guid))) {
        $guid = [guid]$Value
        return [ordered]@{ Kind = 'scalar'; Type = 'Guid'; IsEmptyGuid = ($guid -eq [guid]::Empty); Empty = $false }
    }
    if ($Value -is [string]) {
        return [ordered]@{ Kind = 'string'; Length = $Value.Length; Empty = [string]::IsNullOrWhiteSpace($Value) }
    }
    if ($Value -is [ValueType]) { return [ordered]@{ Kind = 'scalar'; Type = $Value.GetType().Name; Empty = $false } }
    if ($Depth -ge 6) { return [ordered]@{ Kind = 'truncated'; Type = $Value.GetType().Name; Empty = $false } }
    if ($Value -is [System.Collections.IDictionary]) {
        $names = @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object)
        $properties = [ordered]@{}
        foreach ($key in $names) { $properties[$key] = Get-DlpShapeNode $Value[$key] ($Depth + 1) }
        $empty = -not @($properties.Values | Where-Object { -not $_.Empty }).Count
        return [ordered]@{ Kind = 'record'; Type = $Value.GetType().Name; PropertyCount = $names.Count; Properties = $properties; Empty = $empty }
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @(foreach ($item in $Value) { Get-DlpShapeNode $item ($Depth + 1) })
        $empty = -not @($items | Where-Object { -not $_.Empty }).Count
        return [ordered]@{ Kind = 'collection'; Type = $Value.GetType().Name; Count = $items.Count; Items = @($items | Select-Object -First 3); Empty = $empty }
    }
    $properties = [ordered]@{}
    foreach ($property in @($Value.PSObject.Properties | Where-Object { $_.IsGettable } | Sort-Object Name)) {
        $properties[$property.Name] = Get-DlpShapeNode $property.Value ($Depth + 1)
    }
    $empty = -not @($properties.Values | Where-Object { -not $_.Empty }).Count
    [ordered]@{ Kind = 'object'; Type = $Value.GetType().Name; PropertyCount = $properties.Count; Properties = $properties; Empty = $empty }
}

function Get-DlpRuleDependencyShape {
    param([string[]]$Policy)
    foreach ($command in 'Get-DlpCompliancePolicy', 'Get-DlpComplianceRule') {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "$command is not available. Run this inside the connected Security & Compliance session."
        }
    }
    $policies = @(Get-DlpCompliancePolicy -ErrorAction Stop)
    foreach ($selector in $Policy) {
        $matched = @($policies | Where-Object {
            $selector -in @([string](Get-DlpField $_ 'Name').Value, [string](Get-DlpField $_ 'Guid').Value, [string](Get-DlpField $_ 'Identity').Value)
        })
        if ($matched.Count -ne 1) { throw "Selector '$selector' matched $($matched.Count) policies; use a unique name or GUID." }
        $parent = $matched[0]
        $parentName = [string](Get-DlpField $parent 'Name').Value
        $parentGuid = [string](Get-DlpField $parent 'Guid').Value
        $parentIdentity = [string](Get-DlpField $parent 'Identity').Value
        $parentId = if ($parentGuid) { $parentGuid } else { $parentIdentity }
        foreach ($rule in @(Get-DlpComplianceRule -Policy $parentId -ErrorAction Stop)) {
            $dependency = Get-DlpField $rule 'ExternalScenarioDependancies'
            $reportedParent = [string](Get-DlpField $rule 'ParentPolicyName').Value
            $ruleGuid = [string](Get-DlpField $rule 'Guid').Value
            [pscustomobject]@{
                PolicyName = $parentName
                PolicyId = $parentId
                RuleName = [string](Get-DlpField $rule 'Name').Value
                RuleId = if ($ruleGuid) { $ruleGuid } else { [string](Get-DlpField $rule 'Identity').Value }
                RuleReportedParentPolicy = $reportedParent
                ParentMatchesQueriedPolicy = ($reportedParent -eq '' -or $reportedParent -in @($parentName, $parentGuid, $parentIdentity))
                HasExternalScenarioDependanciesProperty = $dependency.Has
                ExternalScenarioDependanciesShape = if ($dependency.Has) { Get-DlpShapeNode $dependency.Value } else { $null }
                EmptyProtectionAlertPlaceholder = if ($dependency.Has -and
                    $dependency.Value -is [Collections.IDictionary] -and
                    $dependency.Value.Count -eq 1 -and $dependency.Value.Contains('ProtectionAlertId')) {
                    $alert = $dependency.Value['ProtectionAlertId']
                    $alertId = [guid]::Empty
                    ($alert -is [guid] -or $alert -is [string]) -and
                        [guid]::TryParse([string]$alert, [ref]$alertId) -and $alertId -eq [guid]::Empty
                } else { $false }
            }
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') { Get-DlpRuleDependencyShape -Policy $Policy }