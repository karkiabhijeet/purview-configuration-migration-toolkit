# Purview Configuration Migration Toolkit

A guarded PowerShell toolkit for selectively exporting Microsoft Purview configuration
from one Microsoft 365 tenant and recreating it in another.
Designed for scenarios such as preparing configuration in a demo or test tenant,
then recreating supported settings in a separately authorized destination tenant.

**Community preview (0.1.0).** This is a community project, not an official Microsoft
product or supported Microsoft migration service. Local automated tests use synthetic
data and mocked service commands. This is not a universal/full-fidelity backup solution
or a live-tenant-certified migration tool. Validate in two authorized test tenants
before using it with production configuration.

> **Recommended reading: [Customer guide - step-by-step workflow](docs/CUSTOMER-GUIDE.md).**
> Read it before your first export or import. It explains sign-in, every wizard option,
> destination mappings, label/SIT prerequisites, verification and recovery.
> This README is the overview and quick start; the guide is the detailed operating reference.

## Documentation

| Start here | What it covers |
|---|---|
| [Customer guide (recommended)](docs/CUSTOMER-GUIDE.md) | End-to-end customer workflow, prompts, dependency choices, manual review and troubleshooting |
| [Supported settings and limitations](docs/SUPPORTED-SETTINGS.md) | Exact feature boundaries, metadata handling, XML restrictions and verification limits |
| [Example PowerShell workflow](examples/Example-Workflow.ps1) | Reusable-command examples for administrators who do not use the wizard |

## How migration works

1. **Export from the source:** sign in, select solutions and individual objects, and
   write a new local package. Export reads source configuration; it does not change it.
2. **Prepare the destination:** establish any missing labels, custom SITs and other
   dependencies. Map source references to their intended destination counterparts.
3. **Preview:** sign in to a different tenant, review scopes, names, references and
   exact prepared parameters. Offline package validation alone is not destination readiness.
4. **Import with explicit approval:** create new objects or explicitly reuse existing
   ones. No automatic overwrite. DLP is created disabled; auto-labeling uses simulation.
5. **Verify and test:** read back supported configuration, then test workload behavior,
   label semantics and alerts before deliberate activation. Label publishing is separate.

**A successful export is not a successful migration.** Configuration read-back is not
proof of equivalent protection, alert delivery, distribution or enforcement.

## What is included

| Module | Migration unit | Destination behavior |
|---|---|---|
| SensitivityLabels | Labels and required parent labels | New labels; no automatic publishing |
| AutoLabeling | Service-side policies and their rules | Simulation (`TestWithoutNotifications`) |
| LabelPublishing | Publishing policies and label dependencies | Deferred until explicitly requested; destination order requires manual review |
| DataLossPrevention | DLP policies and their rules | Disabled (`Disable`) |
| SensitiveInformationTypes | Whole conventional custom SIT XML rule packages | New package ID; original entity IDs |

The master module shares one engine between its interactive wizard and reusable commands.
The five feature modules define explicit supported fields and service commands. Unsupported
populated fields on selected objects or dependencies **block export**, rather than being
silently omitted. See [supported settings](docs/SUPPORTED-SETTINGS.md).

Not included: IRM policy migration, trainable classifier model transfer, EDM/fingerprint
migration, content/history migration, existing-object updates, automatic rollback,
or automatic production enforcement.

## Requirements

- Windows and PowerShell **7.4+**.
- `ExchangeOnlineManagement` **3.9.0+**, installed separately.
- Appropriate Purview permissions and licenses in both tenants.
- Modern authentication/MFA. No credentials or tokens are written to packages.
- For local tests only: Pester **5.x**.

The toolkit never installs dependencies automatically.

## Get the toolkit

Clone this repository, or use GitHub's **Code > Download ZIP** and extract it:

```powershell
git clone https://github.com/karkiabhijeet/purview-configuration-migration-toolkit.git
Set-Location .\purview-configuration-migration-toolkit
```

Run the following steps from that folder in PowerShell 7.4 or newer. Follow your
organization's script execution and dependency installation policies; no execution-policy
bypass is required or recommended by this guide.

### Check your PowerShell version

In the **same terminal** where you intend to run the wizard, enter:

```powershell
$PSVersionTable | Select-Object PSVersion, PSEdition
```

`PSVersion` must be **7.4 or newer** and `PSEdition` must be `Core`. Windows
PowerShell 5.1 reports `Desktop` and is not supported. If the wizard is currently
open, enter `q` at its operation menu before running the check.

To start an installed PowerShell 7 from an older terminal, run `pwsh`, then check
the version again in the new prompt. PowerShell 7 is a separate process, so sign
in again when the wizard asks. If `pwsh` is not recognized, install PowerShell
7.4 or later from your organization's approved source; see Microsoft's
[PowerShell installation guidance](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows).

The launcher has a `#Requires -Version 7.4` guard. If you started the wizard
using `Start-PurviewMigration.ps1` and reached its menu, PowerShell 5.1 would
already have been rejected in that process. An `Object ... has no stable identity`
error means the toolkit could not identify a source record; it does not, by itself,
identify whether the response shape or the toolkit's handling caused the problem.

## Start the wizard

From the project directory in `pwsh`:

```powershell
.\Start-PurviewMigration.ps1
```

**You do not need to look up a tenant ID.** Sign in interactively, complete MFA, then
confirm the displayed account and discovered tenant ID. **Source admin sign-in email
(optional)** means the account for the tenant you are exporting **from**; destination
means the different tenant you are importing **into**. Press Enter to choose an account
during Microsoft sign-in instead. The email is not proof of which tenant SSO selected.
Use authorized test tenants first.

## Wizard options

The wizard has two different numbered menus:

| Main operation menu | What it does |
|---|---|
| **1 - Export** | Select source solutions/objects and create a local package; source reads only |
| **2 - Validate offline** | Check package hashes/schema; no sign-in or destination readiness check |
| **3 - Preview / import / resume** | Review destination mappings and preflight; writes require confirmation |
| **4 - Publish labels** | Explicitly publish prepared label policies; this can affect users |
| **5 - Verify** | Read back an existing import; no configuration changes |
| **Q - Exit** | Leave the wizard; saved files remain and existing sessions are not automatically disconnected |

Inside **operation 1**, the solution menu is: **1** sensitivity labels, **2**
auto-labeling, **3** label publishing, **4** DLP, **5** custom SIT packages.
For example, to export DLP choose **operation 1**, then **solution 4**, then select
policy numbers such as `1,2` from the displayed policy list. Rules travel with their
selected policy; their names do not indicate extra policy selections.

## DLP prerequisites and migration choices

**Referenced labels and custom sensitive information types must be available in the
destination before the DLP rules can work as intended.** Being present in the source
does not make them available in another tenant. The toolkit does not migrate content
or relabel existing documents.

| Your situation | Current supported choice |
|---|---|
| Referenced labels already exist in the destination | Use identity-only label references and explicitly select/review each destination counterpart. The reusable export command offers `-UseExistingDlpLabels`; the wizard offers this alternative when unsupported label definitions block a DLP-only export. No label settings are created or updated on that path. |
| Referenced labels are missing | Export label configuration separately with solution **1**, or retain the default dependency-bundling path, but only supported settings can be recreated. Unsupported encryption/template/site-and-group settings remain blockers; prepare those destination labels separately if necessary. |
| Referenced custom SITs already exist | Do not re-export them unnecessarily. Map the classifier references to validated destination entity IDs and provide review evidence. |
| Referenced custom SITs are missing | Run a separate export with solution **5**, select the required supported packages, then import them before DLP. Conventional custom SITs migrate as whole XML packages, not individual entities. |
| Users need the labels published | Optionally export the relevant publishing policies with solution **3**. Review destination users/groups and publish separately through operation **4**. A DLP label condition alone does not require migrating a publishing policy. |

**Current behavior, not a future promise:** labels are bundled by default; custom SIT
packages are read only when explicitly selected. The wizard provides guidance for
separate prerequisite exports, but does **not** yet automatically offer or perform
all three follow-on exports at the end of every DLP export.

### DLP alerts: settings versus a source identifier

Supported alert settings, including `GenerateAlert`, `AlertProperties`,
`ReportSeverityLevel` and incident-report settings, are preserved when populated.
Recipients still require destination review and mapping.

An exact `ExternalScenarioDependancies` record containing only a valid
`ProtectionAlertId` GUID is treated as source response metadata. Its ID is not a
`New-DlpComplianceRule` input and is not copied, mapped or populated in the destination.
New default exports do not need a staged-alert approval. Unknown dependency keys
and malformed records still block.

This does not prove that the destination service allocates an equivalent identifier
or delivers alerts. Compare the destination rule's **Incident reports** settings and
test controlled matching activity before activation. Do not assume that a separate
alert policy must be manually created. Older staged packages retain their original
review/journal requirements; make a new export rather than changing their hashes.

## Worked example: export DLP, then import into a different tenant

The wizard explains each stage before asking for input. These example names and paths
are placeholders: choose your own folder and the actual numbered objects shown.
Dashed cyan headings separate stages; gray indented bullets are guidance, yellow is
caution, green identifies confirmed identities/completed steps, and red marks failures.
Text labels and separators remain readable without color.

| Stage / prompt | What to enter and what to expect |
|---|---|
| **Operation menu** | `1` exports. **Do not choose operation 4 for DLP**: operation 4 publishes labels. |
| **Export 1/5: source sign-in** | Optional **Source admin sign-in email**: the admin email for the tenant you are exporting FROM. Press Enter to open Microsoft sign-in and choose the account there. If already connected, `Y` reuses or `S` disconnects and switches. Confirm the displayed source with `Y`; `N` lets you switch. No GUID input. |
| **Export 2/5: solution selection** | `4` selects **DLP here**. `1,4` selects labels and DLP; `*` selects every solution. |
| **Export 3/5: objects** | Read the numbered policy list. Enter `1`, `1,3`, or `*`; Enter skips that solution. Rules and supported label dependencies travel with the selection. Custom SIT packages are not bundled with DLP; select solution 5 separately only when needed. |
| **Export 4/5: new export folder** | Type, for example, `C:\PurviewExports\Demo-DLP-Run01`. This is a folder on your computer/approved share, **not** a SharePoint URL or XML filename. The tool creates it; **do not create the final folder first**. Existing folders are rejected. There is no automatic default. |
| Optional destination name prefix | For example `Migrated-`, or Enter for unchanged ordinary names. Does not change label display names. SIT packages have a `Migrated-` default name. |
| **Export 5/5: completion** | See the resolved folder, object count and generated instructions. Choose `Y` to disconnect the source; removal is verified. Protect this folder as security configuration. |
| **Operation menu** | Optional `2` validates the package locally without signing in. Then `3` previews/imports into the destination. |
| **Package folder** | Enter keeps the last successful folder in this wizard; in a fresh process, type its path. Select the folder, not a file. |
| **Mappings file** | Enter selects that package's `mappings.json`; use another existing mappings file only if you prepared it for this package. |
| **Destination sign-in** | Sign in to the other tenant and confirm the displayed identity. If source is still connected, use `S` to switch. Source cannot be destination. |
| **Guided mappings** | `Y` guides choices for each included object: `C` create, `R` choose an existing object, `K` keep a reviewed choice, `M` leave for manual review. Create requires a unique name; Enter keeps the shown name. Reuse never updates an existing object. |
| Optional display name / priority | Labels can override display text. Where priority is supported, Enter retains the current choice, a nonnegative integer overrides, and `SOURCE` clears an override. Publishing order is manual, not a numeric override. |
| External references | `E` enters a destination value, followed by your explicit validation and evidence; `K` keeps the current value; `M` defers to manual review. For a DLP custom classifier, map to the existing destination entity ID if already migrated; otherwise export/import its SIT package separately first. The toolkit does **not** automatically verify every resource. `All` remains destination-wide `All`. |
| Save / complex review | Review the mapping summary and `Y` saves local instructions. For complex settings, the wizard shows the exact file, object key and evidence fields. Edit only mappings, then `C` reloads; `B` returns to the menu for later resume. |
| **Online preview** | Read warnings/blockers and `last-preview.json`. There are **no service writes** yet. Fix every blocker before continuing. |
| **Write authorization** | For a dry trial, answer `N`. To execute, answer `Y`, verify the displayed destination, and type exact uppercase `IMPORT`. Any other phrase cancels. No GUID retyping. |
| DLP alert response identifier | An exact `ExternalScenarioDependancies` record containing only a valid `ProtectionAlertId` GUID is excluded as source response metadata, without a staged-export prompt. Supported alert/incident-report settings remain included. Compare destination settings and test alert behavior before activation; read-back does not prove delivery or automatic identifier allocation. Unknown dependency fields still block. Older staged packages retain their review requirements; make a new export for the simplified flow. |
| DLP label dependencies | By default, referenced label definitions are bundled. If unsupported label settings block a DLP-only export, the wizard offers **use existing destination labels** (`-UseExistingDlpLabels`): export identities only, then select and review each destination label. No label configuration is exported, created or updated. Labels must exist before DLP import; `Create` is forbidden. Decline to retain full label-migration requirements. |
| Result / verification | Inspect status and journal; operation `5` reads back the existing import. DLP is created **disabled**, auto-labeling in **simulation**. Workload testing and manual activation are separate. |
| Label publication, if applicable | Operation `4` needs a separately reviewed plan and exact `PUBLISH`. It exposes labels/settings to users; it is not inactive staging. It can also create other pending mapped objects. |

`Q` cancels the current operation; at the main menu it exits. Ordinary invalid inputs
reprompt without losing selections. Saved files remain when cancelling. Exit does not
disconnect automatically: disconnect explicitly or close your dedicated PowerShell process.
If an error occurs after import begins, inspect the journal before retrying; there is no
automatic rollback.

The export contains `manifest.json` (identity/hashes), `objects.json` (definitions),
optional original SIT XML, `mappings.json` (destination instructions), and
`NEXT-STEPS.txt` (handoff). **Do not edit source definitions/XML or their hashes.**
The wizard adds a preview and, during import, a resumable journal and prepared SIT XML.
Once a journal exists, mapping content is bound and the wizard treats it as read-only.

For `AdvancedRule`, `LabelActions`, encryption/protection dependencies and publishing order,
review the prepared parameters and destination semantics, not just object names.
The wizard does not automatically approve those settings. See the
[complete prompt reference and troubleshooting](docs/CUSTOMER-GUIDE.md).

## Reusable commands

```powershell
Import-Module .\PurviewMigration.psd1

# Interactive sign-in discovers the actual tenant. UPN hint is optional.
$source = Connect-PurviewMigrationTenant
# Inspect $source and confirm it is the intended source before exporting.

Export-PurviewMigrationPackage -SourceTenantId $source.TenantId `
    -Selection @{ Dlp = @('Demo DLP policy') } `
    -UseExistingDlpLabels `
    -Path .\exports\customer-demo-01

Disconnect-PurviewMigrationTenant -Confirm:$false
```

The example above assumes required destination labels already exist and must be
explicitly reused and reviewed; it does not export their configuration. Custom SIT
references also require reviewed mappings. See the customer guide before executing.

Edit and review the generated mappings, then in the destination session:

```powershell
$destination = Connect-PurviewMigrationTenant
# Confirm the displayed account/tenant is the intended destination.
$destinationTenantId = $destination.TenantId

$paths = @{
    Path = '.\exports\customer-demo-01'
    MappingsPath = '.\exports\customer-demo-01\mappings.json'
}
New-PurviewMigrationPlan @paths | ConvertTo-Json -Depth 100

Import-PurviewMigrationPackage @paths `
    -DestinationTenantId $destinationTenantId `
    -ConfirmDestinationTenantId $destinationTenantId -WhatIf

# Only after reviewing the plan:
Import-PurviewMigrationPackage @paths `
    -DestinationTenantId $destinationTenantId `
    -ConfirmDestinationTenantId $destinationTenantId -Confirm:$false
```

See the [customer guide](docs/CUSTOMER-GUIDE.md) for all-object selections, reuse,
reference validation, XML boundaries, publishing, and recovery. The
[example workflow](examples/Example-Workflow.ps1) performs no authentication or migration
unless its functions are explicitly called.

Advanced scripts can still supply `-TenantId $expectedTenantId` to
`Connect-PurviewMigrationTenant` to reject a different authenticated tenant.
CLI users prepare mappings explicitly; the guided mapping interface is in the wizard.

## Validate locally

```powershell
.\Tests\Invoke-Validation.ps1
```

This parses the PowerShell files, validates the module manifest, and runs Pester tests
without tenant authentication. CI runs the same command on Windows.

## Handling exports and publishing this project

Migration packages contain organizational security configuration. Restrict access,
keep them outside source control, and review their retention with the customer.
Hashes detect accidental changes; they are **not digital signatures**.

Project repository:
[karkiabhijeet/purview-configuration-migration-toolkit](https://github.com/karkiabhijeet/purview-configuration-migration-toolkit).
Publish toolkit source, synthetic examples/tests and documentation only.
Do not publish tenant exports, customer packages, mappings, journals, prepared XML,
previews, credentials or logs, even in an issue or troubleshooting attachment.

A license has not yet been selected or included. Public visibility alone does not
grant an open-source license; choose one and review redistribution terms before
customer redistribution.

## Official documentation

- [Connect to Security & Compliance PowerShell](https://learn.microsoft.com/en-us/powershell/exchange/connect-to-scc-powershell)
- [Sensitivity labels](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-label)
- [Auto-labeling policies](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-autosensitivitylabelpolicy)
- [Publishing policies](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-labelpolicy)
- [DLP policies](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-dlpcompliancepolicy)
- [Custom SIT XML export](https://learn.microsoft.com/en-us/purview/sit-modify-a-custom-sensitive-information-type-in-powershell)
- [Custom SIT package import](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-dlpsensitiveinformationtyperulepackage)
- [Portal ZIP exports are reference-only, not import packages](https://learn.microsoft.com/en-us/purview/purview-policy-export)
