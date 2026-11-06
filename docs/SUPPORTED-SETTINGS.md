# Supported settings and limitations

The authoritative allowlists are in the five feature modules. This release intentionally
does not guess at unknown properties. Populated source fields outside the allowlist
and documented read-only metadata block the selected object's export. Fields on
unselected, unrelated ordinary objects do not block another object's export.

## Feature coverage

| Type | Supported configuration families | Important boundaries |
|---|---|---|
| Sensitivity labels | Names/display/tooltip/comment, content type, parent/group, locale/settings, raw label actions, conditions, header/footer/watermark settings, listed encryption settings, default content label, priority | No general site/group protection or new/unknown feature parameters. Protection services and rights need destination review. Raw action payloads are preserved, not reinterpreted as portable encryption trust. |
| Auto-labeling policies | Applied label, Exchange senders/locations, SharePoint/OneDrive inclusions/exclusions, overwrite, priority | Service-side policies only; not all adaptive scopes/new workloads. Simulation replaces source mode. |
| Auto-labeling rules | Workload, priority/disabled, advanced rule, sensitive information predicates/exceptions, access scope, selected extension/name/sender/recipient conditions | Unsupported populated condition/action properties block export. |
| Publishing policies | Labels, settings/advanced settings, Exchange and modern-group scope/exceptions | Creation deferred; no automatic publication. Source priority is exported for reference; destination publishing order requires an explicit manual-review acknowledgement. |
| DLP policies | Names/comment, priority, Exchange/group, SharePoint/OneDrive, Teams, endpoint and Power BI locations/exclusions | Not all adaptive scopes, connectors, or global endpoint settings. Disabled mode replaces source mode. |
| DLP rules | Advanced rule, sensitive information predicates/exceptions, access/block settings, selected notifications/incident reports/alerts, endpoint restrictions, sender/recipient/extension conditions, restrict-access settings | Not a claim that every advanced-rule subtype or newly introduced workload is portable. Unsupported top-level fields block; review structured payloads in the preview. |
| Conventional custom SITs | RulePackage XML with Entity definitions and local regex/keyword resources | Whole package is the unit; new package ID, original entity IDs; external resources require manual evidence. No managed-package overwrite/merge or entity-ID rewriting. Packages without supported Entity definitions are not migrated. |

The tool checks destination cmdlet parameter availability against RBAC/module metadata.
An API parameter's existence does not prove a feature is licensed, ready, or semantically
portable. Service calls can still fail explicitly.

## Guided choices versus manual review

DLP-only exports can explicitly choose `-UseExistingDlpLabels` instead of exporting
referenced label configuration. This creates hashed identity-only
`ExistingLabelReference` records (the source objects file is hashed by the manifest),
not incomplete label definitions for creation. Their only configuration field is
the name; no source encryption, template, capability, parent or site/group settings
are exported. Only labels referenced by DLP rules are included; label configuration
dependencies are not pulled in. This does not expand label-migration support.
The default strict export remains unchanged.

These references require `Action=Reuse`, a valid existing destination label GUID,
`ExistingLabelReviewed=true` and `ExistingLabelEvidence`. The wizard guides selection
and evidence; online preflight verifies unique existence. Creation is forbidden,
including on resume. Names are not evidence of semantic equivalence. Verification is
`ReusedExistsNotContentVerified`; the batch status is
`ConfigurationVerifiedReusedLabelsNotContentVerified` unless a higher-priority
manual-alert status applies. The import result always lists `ExistingLabelReferences`.
Unknown DLP fields still block. The known source alert identifier does not require
an opt-in on new default exports; older staged packages retain their review contract.

The wizard guides create/reuse, names, supported display-name/priority overrides and
exact external-reference values. This does not expand the field allowlists or establish
resource semantics automatically. It discovers tenant identity after sign-in; optional
expected-tenant validation remains available in reusable commands.

Complex payloads, meaningful encryption settings, publishing settings/order and external
protection/XML dependencies still need an explicit destination review. The wizard shows
the mappings path/object keys and pauses for evidence rather than setting approval flags.
An `All` scope remains destination-wide `All`. Existing journals make mappings read-only;
neither guided choices nor a new sign-in bypasses journal binding.

## Normalization and comparison

The single-key DLP response record `ProtectionAlertId` is excluded as source metadata
when its value is a valid GUID, empty or nonempty (live GUID or normalized string).
It is not a `New-DlpComplianceRule` input and is never copied or mapped. Malformed
IDs, additional keys and unknown structures still block. Supported alert settings
and mapped alert/incident-report recipients remain preserved and read-back checked.
Plans and generated next steps call for destination settings/behavior testing;
read-back is not alert-delivery validation or proof of automatic ID allocation.
No separate alert-policy creation requirement is inferred from this response field.

Existing packages with a hashed `AlertReview` marker retain acknowledgment, status
and journal binding for compatibility. `-AllowDlpAlertReview` explicitly retains that
legacy contract; the wizard does not use it. Default new exports have no marker or
per-rule alert-ID acknowledgment. Re-export rather than altering older package hashes.

DLP rules preserve the documented `NotifyEmailExchangeIncludeAttachment`,
`NotifyEmailOnedriveRemediationActions`, `NotifyPolicyTipDisplayOption`,
`NotifyUserType` and `EnforcePortalAccess` creation parameters, including false
boolean values. Destination parameter availability is checked before writes.
`ParentPolicyName`, `ObjectClass` and `OrganizationalUnitRoot` are excluded metadata;
rules remain linked to the explicitly resolved destination policy.
`IsAdvancedRule` is excluded only when it is a boolean consistent with the presence
of `AdvancedRule`. `ExternalScenarioDependancies` is not blanket-ignored: only
structurally empty values (null, blank, `[]`, `{}`, empty collections or records whose
values are all empty) and the exact valid `ProtectionAlertId` GUID record are recognized;
other populated or unknown forms, including scalars, still block export. Export reads
rules only for selected policies.
Rule blockers report value shapes without payload values.

- All normalized fields are allowlisted; raw Get output is never blindly splatted into New.
- Read-only identity/distribution/status/internal metadata is excluded.
- DLP policy `DistributionSyncStatus`, `ObjectClass`, `OrganizationalUnitRoot` and
  `PolicyRulesMetaData` are excluded as service status, directory and rule-summary
  metadata; actual rules are read separately. `Type`, `GlobalListType`,
  `PolicyConstraints`, `PolicyCategory` and `Locations` are not blanket-ignored.
  Populated unsupported values still block; export diagnostics report types/counts
  without payload values. `Locations` is a documented creation parameter but its
  returned representation requires a supported scope adapter before migration.
- DLP default-only values are recognized: `Type=Dlp`, `GlobalListType=None`,
  `PolicyCategory=Unknown`, JSON `Locations=[]`, and `PolicyConstraints` containing
  exactly empty `AdministrativeUnit` and `DynamicRiskPrevention` arrays. These carry
  no additional scope/constraints and are not sent to creation. Nondefault values,
  nonempty scopes/constraints, unexpected constraint keys and malformed JSON still
  block rather than being ignored. Existing workload-specific location fields remain
  exported and verified.
- Destination IDs are obtained from creation results, not assumed equal to source label/policy IDs.
- Recognized scalar identity fields are used directly; nested identity objects are
  resolved only through their explicit `Guid`, `ImmutableId`, `Identity`, or `Id` fields.
  An empty GUID is not an identity; another recognized identity must be available.
  An unrecognized structure blocks rather than becoming a generic type-name string.
- SIT rule packages use their package-specific `RuleCollectionName` / `LocalizedName`
  metadata and validated XML `RulePack` GUID, rather than requiring generic policy
  `Name` / `Identity` values. The built-in package is not copied. Original XML bytes
  are retained, and summary-only retrieval must return the matching package.
  When SIT packages are explicitly selected for cataloging, a well-formed package
  with a valid RulePack GUID but no supported `Entity` records is retained only as
  an unsupported dependency marker. It is
  omitted from an export if unrelated; selecting it or an exact identifier match from
  a selected object's references blocks export with a sanitized XML structure summary.
  Malformed XML or a package without a stable RulePack GUID still blocks cataloging,
  because the tool cannot safely establish its identity or relevance.
  Export, package validation and import preparation use XML byte-stream encoding
  detection, including BOM-less UTF-16; prepared destination XML uses UTF-8.
  SIT resume validates identity and prepared XML content; an internal service
  `RuleCollectionName` is not assumed equal to the migrated XML display name.
- Dependencies are ordered before their consumers; policy rules remain associated with their policy.
- DLP export does not enumerate or include custom SIT packages implicitly. Custom classifier IDs in DLP rule payloads become external references for explicit destination mapping. Export required SIT packages separately only if they are absent from the destination; importing an existing package again is unnecessary.
- Reference-bearing fields use exact-value mapping, including parsed JSON values, not substring/domain replacement.
- Recognized advanced-rule classifier/reference conditions are mapped structurally;
  unrelated content-match literals and classifier group display names are preserved.
- Raw `AdvancedRule` / `LabelActions` payloads require explicit structured-payload review
  evidence. Raw label actions use only explicitly reviewed external mappings, not automatic
  replacement of label display text.
- Display text, descriptions and names are not globally rewritten as references.
- JSON object key order/formatting is normalized; array ordering is preserved.
- Supported read-back fields and policy membership are checked, including a final batch check.
  SIT XML uses a structural comparison that ignores formatting/attribute order.
- Reuse validates identity/existence and rule association, not full equivalence of a pre-existing object's configuration.
- Changes in service serialization can produce a verification failure requiring manual review;
  that failure is not converted into success.

## Unsupported or deliberately deferred

- IRM policy export/import/recreation via undocumented/private interfaces.
- Custom trainable classifier model transfer, EDM datasets/schemas, document fingerprints.
- Device onboarding, connector setup, global endpoint/IRM configuration.
- Content migration, protected-document relabeling, encryption keys/trust, alerts/cases/history.
- Existing-object updates/deletes, silent conflict resolution, automatic rollback.
- Automatic production DLP or auto-labeling enforcement.
- App-only authentication certification and cross-platform/PowerShell 5.1 support.

External-resource review is manual where the toolkit lacks a specific destination
lookup adapter. `Reviewed` and `Evidence` are explicit attestations, not proof from
Microsoft APIs. Independently verify all tenant-bound structured settings and encryption
dependencies, especially raw label actions and advanced rules.

`Set-LabelPolicy` exposes `NextLabelPolicy` / `PreviousLabelPolicy`, not `Priority`.
Publishing order is therefore explicitly deferred for manual verification rather than
passed to an unsupported command parameter. See the customer guide for its acknowledgement
fields and distinct result status.

## Microsoft references

- [Get-Label detailed actions](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-label)
- [New-Label parameters](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-label)
- [New-AutoSensitivityLabelPolicy](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-autosensitivitylabelpolicy)
- [New-AutoSensitivityLabelRule](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-autosensitivitylabelrule)
- [New-LabelPolicy](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-labelpolicy)
- [New-DlpCompliancePolicy](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-dlpcompliancepolicy)
- [New-DlpComplianceRule](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-dlpcompliancerule)
- [Custom SIT XML](https://learn.microsoft.com/en-us/purview/sit-modify-a-custom-sensitive-information-type-in-powershell)
