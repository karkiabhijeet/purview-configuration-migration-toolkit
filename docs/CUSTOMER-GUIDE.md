# Purview Configuration Migration Toolkit - Customer Guide

**Recommended operating guide for the community preview.** Start with the
[README overview and quick start](../README.md), then use this guide for the detailed
export, mapping, import, verification and recovery steps. This is not an official
Microsoft migration product or a full-fidelity backup/restore service.

For DLP, source labels/SITs are not automatically available in another tenant:
prepare missing destination dependencies first and review every mapping. See
[DLP label choices](#dlp-rules-referencing-sensitivity-labels) and
[alert response metadata](#dlp-rule-response-metadata). A completed package or
configuration read-back does not certify end-to-end protection or alert delivery.

## Before starting

Use PowerShell **7.4 or newer on Windows** (`pwsh`, not Windows PowerShell 5.1).
Install ExchangeOnlineManagement 3.9.0 or newer through your organization's approved
package source. For local validation, install Pester 5.x separately.

In the same terminal that will run the wizard, check
`$PSVersionTable | Select-Object PSVersion, PSEdition`. Version 7.4 or newer
with edition `Core` is supported; 5.1 with edition `Desktop` is not. If the
wizard is open, enter `q` at the operation menu first. The launcher blocks an
older version before its menu appears. See the [README version check](../README.md#check-your-powershell-version)
for how to start PowerShell 7.

Obtain authorization for both tenants, the relevant Purview administrative roles,
and licensing for the features/workloads being recreated. Roles determine which
commands and parameters are available. The tool checks command availability, not
every licensing entitlement or service-side prerequisite.

Use a dedicated PowerShell process. The initial authentication path is interactive
modern authentication/MFA; unattended app-only compatibility is not certified.
Noninteractive export/import commands require an already authenticated, validated
session and explicit parameters; they do not initiate an account picker.

## Wizard: what to expect at every step

Start with `.\Start-PurviewMigration.ps1`. The [README DLP walkthrough](../README.md#worked-example-export-dlp-then-import-into-a-different-tenant)
is the beginner path. The sections below also describe the reusable-command workflow;
manual JSON preparation is **not** required for ordinary wizard mappings.

### Operations and authentication

| Operation | Inputs / result | Authentication / service writes |
|---|---|---|
| 1 Export | Solutions, objects, a new custom folder, optional name prefix; creates a validated local package | Confirm source sign-in; service reads only |
| 2 Validate | Existing package folder; hash/schema result | No authentication; no service writes |
| 3 Preview / import / resume | Existing package and mappings; destination sign-in, guided choices or unchanged bound mappings, preview and explicit authorization | Destination reads, then writes only after `Y` and exact `IMPORT` |
| 4 Publish | Same package, mappings and journal; preview, explicit authorization | Destination reads, then writes only after `Y` and exact `PUBLISH`; other pending mapped objects may also be created |
| 5 Verify | Existing package, unchanged mappings, destination sign-in; individual read-back statuses | Service reads only |
| Q Exit | Returns from the wizard; saved files remain | Does not disconnect an existing session |

The wizard separates each stage with cyan headings and dashed lines. Guidance appears
as indented gray bullet lines, cautions in yellow, confirmed identities/completed
steps in green, and failures in red. Text labels and separators still identify the
stages when the host does not display colors.

No tenant-ID lookup is needed. **Source admin sign-in email (optional)** means the
admin sign-in email for the tenant you are exporting **from**; the destination prompt
means the different tenant you are importing **into**. Press Enter to open Microsoft
sign-in and choose an account there instead. Modern sign-in
and MFA discover the actual compliance tenant ID; the wizard shows it with the account.
An existing session offers `Y` reuse, `S` verified disconnect then sign-in, or `Q` cancel.
Confirm the intended source/destination with `Y`, or `N` to choose another session.
If source is still connected during destination work, choose `S`; the source is never
accepted as destination. The final confirmation is the word `IMPORT` or `PUBLISH`,
not a GUID. The underlying import API still receives/checks the actual discovered GUID.

SSO may reuse an account despite a UPN hint. Never treat entering another email as
proof of a switch. If the account picker or session isolation is uncertain, close this
dedicated `pwsh`, reopen it, restart the wizard and use the existing export with operation 3.
Login cancellation/service failures are reported explicitly and return to the menu.

### Selection, folders and naming

- **Solution menu**: `1` labels, `2` auto-labeling, `3` publishing, `4` DLP, `5` custom
  SIT packages. Numbers apply only to this list, not the operation menu.
- **Solution/object selection**: comma-separated numbers or `*`; Enter skips only
  an object list, not the solution list. Exporting nothing is an explicit error.
  Unsupported settings block selected objects rather than being silently dropped.
- **New export folder**: a required filesystem path, for example
  `C:\PurviewExports\Demo-DLP-Run01`. This is not a SharePoint URL or individual XML
  filename. The tool creates the final folder and parent folders as needed.
  **Do not precreate the final folder**: even an empty existing directory is rejected.
  There is no default folder; examples are not automatically used.
- Paths with spaces and pasted surrounding quotes are accepted. Relative paths resolve
  from the current PowerShell directory; the absolute result is displayed.
  Use storage approved for sensitive security configuration.
- **Existing package folder**: choose the folder containing the exported manifest,
  not an XML file. Enter uses the last successful folder only if shown in the same wizard.
  A fresh wizard requires its path.
- **Mappings file**: Enter uses the displayed package `mappings.json`; otherwise give
  an existing instructions file for this package, not the manifest/definitions/preview.
- **Destination name prefix**: Enter leaves ordinary internal names unchanged;
  for example `Migrated-` prefixes those names. This does not change label display
  names. SIT packages already default to `Migrated-<source name>`.
- Invalid selection/path inputs reprompt in place. Filesystem failures during export
  retain selections and offer a different new path. A partial folder is retained for
  inspection, not overwritten, deleted, or reported as a successful package.
- **Source disconnect**: `Y` disconnects and verifies removal; `N` keeps it until an
  explicit switch. Failure to establish isolation is a blocker, not a successful switch.

### DLP rules referencing sensitivity labels

Selecting a DLP policy includes its rules. A rule can match sensitivity labels, so the
default exporter also includes referenced label definitions and their dependencies.
`SensitivityLabels '...' has unsupported populated fields` describes those label
definitions, not extra DLP policies or a PowerShell runtime problem.

If a DLP-only export encounters unsupported label definitions, the wizard offers a
**DLP LABEL DEPENDENCIES** section:

- **Y: use existing destination labels.** Export label identity references only.
  Label configuration (including encryption and site/group settings) is **not**
  exported. Required labels must already exist, or be prepared separately before
  importing this DLP package. The wizard asks you to select the existing destination
  counterpart for each referenced label and record review evidence.
- **N: require label configuration migration and stop.** No package is created.
  Unsupported settings remain blockers; this toolkit does not yet migrate the
  reported capabilities, template linkage and site/group settings. Do not ignore
  them or edit package hashes to bypass them.

The advanced equivalent is `Export-PurviewMigrationPackage ... -UseExistingDlpLabels`.
It is restricted to DLP selections, optionally with custom SIT packages; export other
solutions/label configuration separately. This switch is independent of
the legacy `-AllowDlpAlertReview` option; older staged packages can require both
acknowledgments. New default exports do not require alert-ID acknowledgment.

Identity-only labels have an `ExistingLabelReference` marker and `Action=Reuse` in
`mappings.json`. `Create` is prohibited. Select a nonempty destination label GUID
and set `ExistingLabelReviewed=true` plus `ExistingLabelEvidence` only after
independently checking label meaning, scope and protection. Similar names do not prove
equivalence. Online preflight checks that the destination label uniquely exists.
Import and resume never create or update these labels.

Read-back reports `ReusedExistsNotContentVerified` for these label references. The
batch reports `ConfigurationVerifiedReusedLabelsNotContentVerified` unless alert
follow-up is also pending, in which case its manual-alert status takes precedence.
`ExistingLabelReferences` in the import result lists the reused label references in
either case. These statuses do not certify label equivalence or workload behavior.
Keep DLP disabled until the mapped conditions and protection have been validated.

### Guided mappings, saving and manual handoff

Before any service writes, the wizard offers guided choices:

| Prompt | Accepted choices / meaning |
|---|---|
| Guide mappings now? | `Y` guides new/unbound instructions and fills the confirmed destination ID; `N` preserves the file for manual review. An unbound file gets explicit handoff instructions, not a guessed tenant. |
| Object action | `C` create; `R` choose an existing numbered destination object; `K` keep the current reviewed choice; `M` leave it for manual review. `K`/`M` do not approve `Review`. |
| Existing object | Exactly one numbered object. IDs are shown; preflight verifies uniqueness/association. No match means manual review, not fabricated reuse. |
| Destination name | Enter keeps the displayed name; otherwise supply a new unique name. No overwrite/update. |
| Label display name | Optional label-only display-text override; Enter retains the current override/source text. |
| Priority | Where the exported object supports priority: a nonnegative integer overrides; Enter keeps current; `SOURCE` clears an override. Publishing priority is excluded. |
| External reference | `E` enters/reviews an exact destination value; `K` keeps the current value; `M` defers. An unchanged value still requires independent validation. |
| Reference validated? / evidence | `Y` plus a concrete nonempty account of what you checked; `N` leaves it unreviewed. Evidence is not an automated resource lookup. |
| Save instructions? | Review object and reference summaries, then `Y` saves local mappings; `N` discards unsaved guided choices. No service configuration has changed. |
| Complex-review handoff | Exact file path, object key, fields and source reference are shown. Edit only mappings. `C` reloads the file after review; `B` returns to the menu for later; `Q` cancels. |
| Execute reviewed plan? | `N` performs no service writes. `Y` then requires exact uppercase `IMPORT` or `PUBLISH`; any different phrase cancels. |

For complex `AdvancedRule`, `LabelActions`, encryption settings and publishing settings,
the wizard does not set review flags on your behalf. Inspect `objects.json` as a
read-only reference and the exact prepared parameters from the preview command shown.
In the indicated object mapping, use `StructuredPayloadReviewed` and
`StructuredPayloadEvidence` only after a real destination-semantic review.
Publishing order requires separate `PublishingOrderReviewed` and
`PublishingOrderEvidence` acknowledging the destination ordering check.
The detailed mapping section below explains these fields; do not copy sample evidence
as if a review occurred.

All destination-wide `All` scopes remain `All`; the wizard does not invent a test-group
restriction. SIT package creation preserves original entity IDs and uses the generated
new package ID. Entity collisions/unsupported external resources require a supported
package or explicit compatible reuse, not edits to original XML or manifest hashes.

During complex review, or after successful preflight, `last-preview.json` contains
exact prepared parameters and any blockers; its existence alone is not import approval.
Resolve every blocker before authorization. If no journal exists, correct instructions
and rerun operation 3. Once import starts, mappings are hash-bound: the wizard skips
editing and validates the original journal instead. A nonstandard journal path needs
advanced commands with the original `-JournalPath`; the wizard will not guess one.
Cancelling retains saved packages, mappings and journals; it is not rollback.

### Troubleshooting by symptom

| Symptom | Recovery |
|---|---|
| Asked for a folder but unsure what to type | New export: choose a not-yet-existing final filesystem folder. Import/validate: open the existing package folder. Mappings: open the existing destination instructions JSON. |
| Blank path, URL, unavailable drive, or existing export folder | Correct the path at the same prompt; earlier selections remain. Use a new folder for each export. |
| Access denied / partial export | Use approved writable storage and a different new final folder. Retain the partial folder for inspection; do not use it as a valid package unless validation succeeds. |
| Wrong account/tenant / SSO selected source again | Reject the identity; explicitly switch, or use a fresh dedicated process. A different hint alone does not establish a different tenant. |
| Competing, expired or prefixed sessions | Reconnect in a fresh dedicated process. No session is chosen silently. |
| Destination name already exists | Before first import, rename or explicitly reuse a compatible object and its rules. Reuse never updates it. |
| Missing reference evidence / unreviewed payload | Follow the displayed object/key instructions, validate destination resources/semantics, save mappings and reload. Do not blanket-approve complex settings. |
| Hash mismatch / unsupported source field | Recover the original export or prepare a supported source configuration and export anew. Do not edit hashes or silently remove settings. |
| DLP reports unsupported `Type`, `GlobalListType`, `PolicyConstraints`, `PolicyCategory` or `Locations` | The field names alone do not establish whether the returned values are ordinary metadata or meaningful settings. Export reports value types/counts without contents. Share that diagnostic and use an authorized read-only check to establish the returned representation. Do not delete these fields to force export: `Locations` can specify real scope. Service status, directory metadata and rule-summary metadata are excluded separately; actual rules are read independently. |
| DLP returns `Type=Dlp`, `GlobalListType=None`, `PolicyCategory=Unknown`, `Locations=[]` and empty administrative-unit/risk constraints | Reload the updated toolkit. These exact defaults are recognized without removing real settings. The constraints JSON must contain only empty `AdministrativeUnit` and `DynamicRiskPrevention` arrays. Nonempty scopes/constraints, unknown classification values and new constraint keys remain blocked. Existing SharePoint/Exchange/other supported workload scopes are still exported. Retry into a new folder; do not edit previous packages or hashes. |
| `Object '' has no stable identity` during export | The toolkit could not find a recognized identity in a returned or normalized record; the response shape or toolkit handling may be responsible. This is not proof of a tenant-switch failure. The error reports the source cmdlet, result number, response type/property names and script stack without dumping policy payloads. DLP-only export does not enumerate SIT packages; a `Get-DlpSensitiveInformationTypeRulePackage` error means SITs were explicitly selected for this export. Report that diagnostic, redacting sensitive names or IDs. |
| Error identifies `Get-DlpSensitiveInformationTypeRulePackage` with empty generic `Name` / `Identity` | This command runs only when SIT packages are explicitly selected, not during DLP-only export. The adapter uses `RuleCollectionName` / `LocalizedName` and the XML `RulePack` GUID; it does not require generic policy identity fields. Complete returned XML bytes are used directly; summary-only records are retrieved by a documented package identifier. No manual XML edits are needed. |
| SIT XML load fails near the start with a null character (`0x00`) | Reload the updated toolkit and retry export into a new folder. The XML parser now reads the original bytes and detects XML encoding, including UTF-16 without a byte-order mark, throughout export, validation and import preparation. Do not remove null bytes, re-encode original package files or edit hashes. Malformed XML still blocks. |
| SIT package reports no supported `Entity` definitions | This applies to an explicitly selected SIT package. The package is not migrated; export blocks with a sanitized structure summary (root, namespace, child element counts and available type flags). DLP-only export does not enumerate or copy SIT packages. If the classifier is required, confirm whether it already exists in the destination; otherwise request support with the structural summary, not the XML, regexes, keywords or customer data. |
| Mappings changed after import started | Restore the original matching mappings and journal. Do not reset the journal to bypass validation. |
| Interrupted `Creating` / service failure | Inspect journal `LastError` and destination with an authorized admin. Some writes may already exist; do not guess/retry or assume rollback. |
| Verified but policies do not enforce | Expected safe modes: DLP disabled, auto-labeling simulation. Verify workload distribution/detection separately before manual activation. |
| Publication/order still pending | Use separate operation 4 after review; inspect manual publishing order in the portal/documented ordering commands. |

## 1. Connect and select

```powershell
Import-Module .\PurviewMigration.psd1
$source = Connect-PurviewMigrationTenant
$source | Format-List # Confirm this is the intended source.
$sourceTenantId = $source.TenantId
Get-PurviewMigrationInventory -SourceTenantId $sourceTenantId -Types Dlp,AutoLabeling
```

Supported selection keys:

- `SensitivityLabels`
- `AutoLabeling`
- `LabelPublishing`
- `Dlp`
- `SensitiveInformationTypes`

```powershell
$selection = @{
    Dlp = @('Demo policy A', 'Demo policy B')
    SensitivityLabels = @('Confidential')
    AutoLabeling = @('*') # Explicitly select all policies in this module.
}
Export-PurviewMigrationPackage -SourceTenantId $sourceTenantId `
    -Selection $selection -Path .\exports\demo-001 -NamePrefix 'Migrated-'
```

Use a source ID rather than a name if names are ambiguous. A missing selector is
an error; an empty selection does not mean all. Rules travel with their parent
policies, not as independently selected migration roots. Required supported labels,
Required supported labels and parent labels are added automatically. Custom SIT packages are not implicit DLP
dependencies; export them only when explicitly selected. Source configuration is
read-only throughout export.

SIT selection is **package-level** and optional. A DLP policy package does not include
custom SITs. If a required custom SIT is already in the destination, keep it and map
the DLP reference to its validated destination entity ID. If absent, export the SIT
package separately (operation 1, solution 5) and import it before DLP. Selecting one
entity includes its whole rule package; review its contents before importing.

## 2. Understand the package

| File | Purpose | Edit? |
|---|---|---|
| `manifest.json` | Schema/version, source tenant, package ID, file hashes | No |
| `objects.json` | Normalized definitions, dependencies, original references | No |
| `sit-<source package GUID>.xml` | Original conventional custom SIT package | No |
| `mappings.json` | Destination names, create/reuse choices and references | Yes, before import |
| `NEXT-STEPS.txt` | Generated handoff instructions | Reference |
| `last-preview.json` | Wizard's saved plan | Reference |
| `prepared-<destination package GUID>.xml` | XML prepared during import | Reference |
| `import-<tenant GUID>.journal.json` | Destination IDs and resumable state | Do not casually edit |

Source files are hashed. Do not edit them or update their hashes to bypass validation.
Hashes do not authenticate the publisher; accept packages only from trusted sources.
Protect all files as organizational security configuration. Never commit them to GitHub.
Use a new directory for every export.

## 3. Review destination mappings

The generated template deliberately starts with `Action: "Review"`. There is no
silent approval to create everything. The wizard guides ordinary choices and fills the
confirmed destination ID. For reusable commands/manual preparation, obtain it from
`Get-PurviewMigrationSession` after sign-in, set it in mappings, then for each object choose:

- **Create**: use a new `Name`. Normal objects get a service-assigned destination ID.
  Leave their `DestinationId` empty. The tool records the real returned ID.
- **Reuse**: provide the exact existing destination ID. The destination object must
  uniquely exist; it is not updated. Independently validate that its content meets the
  intended dependency semantics. Existence is not content-equivalence certification.
  New rules cannot be attached to a reused pre-existing policy. Reusing an entire
  policy requires reusing its existing rules and verifying their policy association.

Objects containing raw `AdvancedRule` or `LabelActions` payloads also require
`StructuredPayloadReviewed: true` and `StructuredPayloadEvidence` describing your
review of their destination semantics. These payloads can contain tenant-bound settings
that a top-level parameter allowlist cannot fully understand. The preview shows the
actual prepared payload. Only recognized advanced-rule reference conditions are rewritten;
unsupported rewrites block rather than changing arbitrary content-match literals.

Illustrative excerpt (the real object keys and package ID come from your export):

```json
{
  "SchemaVersion": 1,
  "PackageId": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
  "DestinationTenantId": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
  "Objects": {
    "SensitivityLabels:cccccccc-cccc-cccc-cccc-cccccccccccc": {
      "Action": "Create",
      "Name": "Production Confidential",
      "DisplayName": "Confidential",
      "StructuredPayloadReviewed": false,
      "StructuredPayloadEvidence": "",
      "DestinationId": ""
    }
  },
  "References": {
    "https://demo.example.invalid/sites/finance": {
      "Value": "https://production.example.invalid/sites/finance",
      "Reviewed": true,
      "Evidence": "Destination site verified by the authorized production administrator"
    }
  }
}
```

Names need not change solely because the tenant changes. Rename explicitly to avoid
collisions or to adopt production naming. `NamePrefix` prepares names during export;
it does not change label display names. `DisplayName` overrides apply to labels only.
For labels, auto-labeling and DLP objects with an exported priority, an optional
nonnegative integer `Priority` override changes the destination value; `null` retains
the source value. Review priorities for a selective import into an existing policy set.
Source ordinal positions are not necessarily appropriate in another tenant.
Do not alter mapping choices after an import has started; the journal binds to the
canonical mapping content.

Publishing policy order is a special case: `Set-LabelPolicy` has **no `Priority`
parameter**. An exported publishing priority is reference-only, not silently sent to
an invented parameter. Before the first import, set `PublishingOrderReviewed: true`
and provide `PublishingOrderEvidence` accepting a manual destination ordering check.
After explicit publication, inspect ordering in the portal or use Microsoft's
documented `NextLabelPolicy` / `PreviousLabelPolicy` operations. Numeric publishing
priority overrides are blocked. The result remains
`ConfigurationVerifiedManualPublishingOrderRequired` rather than claiming that
publishing priority was automatically preserved.

For external references, set `Value`, `Reviewed: true`, and meaningful `Evidence`.
Examples include users/groups, recipient domains, SharePoint/OneDrive URLs, workspace
IDs, keyword dictionaries, and protection services. **Evidence is a manual
destination-validation attestation**, not an automated lookup of every resource type.
Verify membership and scope as well as existence. Retain the same value only after
checking that it makes sense in production.

There are no substring/domain-wide replacements and no missing-scope fallback to
`All`. An explicitly exported `All` scope remains `All` and now refers to the
destination tenant; preview calls this out.

Built-in SIT names are ordinarily service-provided and do not need copying. GUID
references not resolved to an included custom entity may require explicit mappings.
External trainable models/dictionaries are not automatically transferred.

## 4. Change authentication

```powershell
Disconnect-PurviewMigrationTenant -Confirm:$false
$destination = Connect-PurviewMigrationTenant
$destination | Format-List # Confirm this is the intended destination.
$destinationTenantId = $destination.TenantId
Get-PurviewMigrationSession -ExpectedTenantId $destinationTenantId
```

The tool checks the real `TenantID` from `Get-ConnectionInformation`, requires exactly
one unprefixed connected compliance REST session with an active token, and rejects
the source tenant as a destination. Entering a different UPN alone is not proof of
a tenant switch. Competing connections are blocked, not automatically selected.

If disconnection/session isolation cannot be verified, close this dedicated `pwsh`
process and start a fresh one. Reimport the toolkit, connect only to production, and
resume using the exported package. No source login is needed to import.

If you already know the expected tenant ID, the optional advanced assertion
`Connect-PurviewMigrationTenant -TenantId $expectedTenantId -UserPrincipalName $adminHint`
rejects an authenticated mismatch. The UPN is optional and is only a sign-in hint.

## 5. Preview, import, and verify

```powershell
$paths = @{
    Path = '.\exports\demo-001'
    MappingsPath = '.\exports\demo-001\mappings.json'
}
Test-PurviewMigrationPackage -Path $paths.Path
New-PurviewMigrationPlan @paths -Offline | ConvertTo-Json -Depth 100
$plan = New-PurviewMigrationPlan @paths
$plan | ConvertTo-Json -Depth 100
```

Offline mode checks local definitions/mappings but always returns `CanImport = false`:
it cannot establish destination readiness. Online preflight checks tenant identity,
supported command parameters, names/IDs, dependencies, and mapping review.
Unsupported configuration is blocked, not silently dropped. Inspect `BlockingErrors`,
`Warnings`, `Steps`, and every `Parameters` entry. Some service-side permissions,
resource semantics, quotas, and distribution failures can only surface during service
calls or later verification.

```powershell
Import-PurviewMigrationPackage @paths -DestinationTenantId $destinationTenantId `
    -ConfirmDestinationTenantId $destinationTenantId -WhatIf

# Explicitly authorize writes only after reviewing the plan.
Import-PurviewMigrationPackage @paths -DestinationTenantId $destinationTenantId `
    -ConfirmDestinationTenantId $destinationTenantId -Confirm:$false

Test-PurviewMigrationImport @paths
```

`WhatIf` gates writes locally: it does not trust the service cmdlets' often nonfunctional
`WhatIf` switches. It performs reads/preflight only, without writing a journal.
For reusable commands, the destination confirmation GUID must match both the actual
session and mappings. The wizard passes these GUIDs internally after confirming the
displayed identity and receiving the typed authorization phrase.

DLP starts disabled. Service-side auto-labeling starts in simulation. Source enforcement
state is intentionally not copied. The tool reads back supported configuration; it does
not certify eventual workload distribution or that the policy detects the right content.
Use workload-specific test content, simulation results, and portal checks before activation.

## 6. Publish labels separately

The initial import does not create publishing policies. Labels themselves can exist
without being published. After checking destination labels and user scope:

```powershell
New-PurviewMigrationPlan @paths -PublishLabels | ConvertTo-Json -Depth 100
Import-PurviewMigrationPackage @paths -DestinationTenantId $destinationTenantId `
    -ConfirmDestinationTenantId $destinationTenantId -PublishLabels -Confirm:$false
```

Use the **same unchanged mappings and journal**. Already imported objects are checked
again rather than created twice. Creating a publishing policy can expose labels and
mandatory/default labeling settings to users: there is no invented "disabled publishing
policy" staging state. Enable DLP or enforce auto-labeling manually only after the
appropriate production review and documented simulation requirements.

## DLP rule response metadata

`ExternalScenarioDependancies` can contain a service-returned `ProtectionAlertId`
GUID. An exact record with only this key and a valid GUID (empty or nonempty) is
excluded as source response metadata. It is not a `New-DlpComplianceRule` input:
the source identifier is never copied, mapped or sent to rule creation. Unknown
keys, additional keys, invalid GUIDs and unsupported shapes remain blocked.

Supported `GenerateAlert`, `AlertProperties`, `ReportSeverityLevel`,
`GenerateIncidentReport` and `IncidentReportContent` settings are retained when
populated. Alert/incident-report recipients still require destination reference
review and mapping. Excluding the identifier does not disable or remove these
settings. New default exports need no staged-alert approval or per-rule alert-ID
acknowledgment.

Before activation, compare the destination rule's **Incident reports** settings:
alert toggle, severity, recipients, every-match/threshold settings and email incident
reports. Then test a controlled matching event in an appropriate non-enforcing mode.
Configuration read-back checks supported fields, not alert delivery or automatic
allocation of a destination identifier. Do not assume a separate alert policy must
be created. Automatic identifier allocation has not been live-verified by this toolkit.

### Compatibility with earlier staged packages

Already exported packages with an `AlertReview` marker retain their acknowledgment
and journal contracts. The legacy `-AllowDlpAlertReview` switch remains available
for callers deliberately using that older contract; the wizard no longer requests
it. These packages require `ProtectionAlertReviewed` and `ProtectionAlertEvidence`
documenting the destination alert validation plan/results, and retain the status
`ConfigurationVerifiedManualAlertReviewRequired`. That status does not establish
that a separate protection-alert policy must be manually created.

For the simplified behavior, make a **new export to a new folder**. Do not edit
existing objects, hashes, mappings bound to an import journal, or journals to bypass
their review requirements.

Run the diagnostic with policy names or GUIDs, not rule names; a rule name matching
zero policies does not indicate missing rules.

For DLP rule export errors, supported notification/portal settings are preserved,
not removed to make export succeed. If `ExternalScenarioDependancies` remains
blocked, inspect only that property with an authorized read-only command: null,
blank, `[]`/`{}`, empty collections and records containing only such empty values are
recognized as empty; the exact valid `ProtectionAlertId` record is also excluded.
Other populated forms need a supported adapter. Rules are read only for
the policies you select (plus label dependencies), so a bad rule in an unselected
policy no longer blocks export; the wizard inventory reads no rules, and `*` reads all selected-kind rules.
To see the real structure, run this read-only script in your already connected session (it never signs in or writes, and prints no values):
`.\Tools\Get-DlpRuleDependencyShape.ps1 -Policy 'Policy name or GUID'` and share the output.
An inconsistent `IsAdvancedRule` flag also blocks. Share only redacted metadata or
the reported value shapes, not complete rule payloads.

## SIT XML: what changes and what does not

- SIT responses can have empty generic `Name` and `Identity` fields. The adapter
  recognizes `RuleCollectionName` and `LocalizedName`, and obtains the package GUID
  from validated XML. If metadata names are absent, the default-language XML name
  is used. Full XML bytes already returned by the service are preserved; a summary-only
  response is retrieved by its documented name/identity or available XML package GUID.
  Missing locators, mismatched detail responses, or malformed XML still block.
- A well-formed package without conventional `Entity` definitions is not migrated.
  It blocks only if explicitly selected or an exact identifier in it is referenced
  by a selected object; otherwise it is excluded from that export. Unidentifiable or
  malformed packages are never treated as proof of irrelevance.
- The tool preserves the source XML and prepares a separate destination XML.
  XML byte streams are parsed with XML encoding detection, including UTF-8 and
  UTF-16 with or without a byte-order mark; they are not assumed to be UTF-8.
  Destination XML is prepared as UTF-8 without changing the saved source bytes.
- It assigns a new rule-package GUID and a reviewed package display name. The default
  name is `Migrated-<source name>` (with an optional additional prefix).
- Original SIT **entity GUIDs remain unchanged**, including their local regex/keyword
  references. Destination entity-ID collisions block creation.
- An existing destination `Microsoft.SCCManaged.CustomRulePack` is never overwritten:
  the tool creates a separately identified package through `New-...RulePackage`.
- Reusing a package requires the source entity IDs to be present in the destination.
  Rewriting entity GUIDs or merging destination-managed packages is not supported.
- External `idRef` resources must be explicitly mapped and reviewed. Local XML
  resources stay intact. Built-in function references can also require an explicit
  reviewed identity mapping.
- DTDs/external entity resolution, EDM and fingerprint packages are not supported.

Usually no manual XML edits are required for an ordinary self-contained new package.
For incompatible package structures, entity-ID conflicts, EDM/fingerprint classifiers,
or a merge requirement, stop and prepare a supported separate package using Microsoft's
documented workflow. Do not force changes into the hashed export to make import proceed.
Not every XML rule-package subtype is supported.

## Resume and recovery

The journal is written before each creation and after its returned ID is recorded.

- `Creating` without a recorded destination ID means the service outcome is ambiguous
  (for example a network failure after a server-side create). Automatic retry is blocked.
  Have an authorized administrator inspect the destination and reconcile the operation.
  Do not simply remove the journal and rerun: that can create duplicates or hide conflicts.
- `Created` means the object exists but verification may not have completed. Resume with
  the same mappings and journal to recheck it.
- `Verified` means supported read-back checks passed, not that production enforcement
  is appropriate or service distribution is complete.
- `Reused` records an existing dependency, not a content-equivalence guarantee.
- `VerifiedWithDeferredPublication` means publishing policies remain intentionally deferred.
- `ConfigurationVerifiedManualPublishingOrderRequired` means supported publishing
  configuration was verified, but destination publishing-policy order still needs
  the explicitly accepted manual check.
- `ConfigurationVerifiedManualAlertReviewRequired` means the rule configuration was
  verified, but its source protection alert was not migrated and needs manual setup.
- `Failed` is a failure even if some objects were created. Review `LastError` and entries.

There is no transactional rollback and no automatic deletion. Any authorized manual
cleanup should be limited to positively identified objects created by this import.
Pre-existing destination objects must not be deleted or updated as recovery shortcuts.
Verification retries are bounded and can be configured on import or standalone
verification. A final batch read-back catches drift after earlier objects were
initially verified. XML comparison normalizes formatting/attribute order but remains
strict about content; service-side semantic changes require manual review.

## Live acceptance checklist

Before customer production use, execute an authorized two-test-tenant trial:

1. Create a small label hierarchy, conventional SIT package, linked auto-labeling policy,
   publishing policy, and DLP policy with representative rules.
2. Sign in without a pre-known tenant ID; confirm the discovered source. Export a
   specific subset into a new user-chosen folder and inspect included dependencies.
3. Disconnect and reconnect in a fresh destination process; confirm its discovered identity.
4. Review scopes, names, protection dependencies and external resource evidence.
5. Decline wizard execution and confirm no service writes, then test wrong confirmation
   text and reusable-command WhatIf. Explicitly confirm a reviewed plan to proceed.
6. Import, verify destination IDs/rules and safe modes, then resume without duplicates.
7. Check publication separately and validate actual workload behavior with synthetic content.

Recreating sensitivity labels does **not** move existing labeled/encrypted documents,
RMS protection trust, keys, or rights-management services. IRM alerts/cases/risk history
and policies are not migrated.
