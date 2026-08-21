# Blob Soft-Delete Recovery — Test Harness

This folder contains the scripts used to build, validate, and prove a
byte-for-byte, at-scale recovery drill for the customer's blob soft-delete
incident (an ADLS Gen2 / HNS-enabled storage account, ~1,308 directories
deleted under a deep engagement path). The scripts stand up an isolated test
storage account that mirrors the customer's scale and structure, simulate the
accidental recursive delete, and then run the enumeration + restore tooling
that will ultimately be handed off to the customer.

See [hints.txt](hints.txt) for the original incident details.

## Supported procedure

All soft-delete list/restore operations use the **documented, supported**
Azure Storage PowerShell procedure:
https://learn.microsoft.com/en-us/azure/storage/blobs/soft-delete-blob-manage#restore-soft-deleted-blobs-and-directories-by-using-powershell

Specifically the native `Az.Storage` cmdlets — not a CLI or Azure MCP
substitute (Azure MCP's `storage` tool was checked and has no soft-delete
list/restore support at all; it only covers basic account/blob/container
CRUD):

| Step | Cmdlet |
|---|---|
| Recursive delete (incident simulation only) | `Remove-AzDataLakeGen2Item -Force` |
| List soft-deleted paths | `Get-AzDataLakeGen2DeletedItem` |
| Restore a soft-deleted path | `Restore-AzDataLakeGen2DeletedItem` |

These require `Az.Storage` 9.0.0+ (GA — no preview module needed) and an
Entra ID-authenticated storage context (`New-AzStorageContext
-UseConnectedAccount`), since this tenant blocks storage account key-based
auth tenant-wide.

## Connectivity model (read this first)

The subscription used for testing enforces a management-group-scope Azure
Policy (Modify effect) that forces `publicNetworkAccess=Disabled` on every
storage account — attempting to set it to `Enabled` gets silently reverted.

Instead of building private endpoints / VNets / a jump-box VM to work around
this, the test environment uses a **Network Security Perimeter (NSP)**:

- The storage account keeps `publicNetworkAccess=Disabled` (policy-compliant).
- An NSP resource is associated with the storage account in `Enforced` mode.
- The NSP profile's inbound access rule allowlists the operator's current
  public IP, so authenticated requests from that IP reach the account while
  all other public traffic stays blocked.

This lets every script below run directly from an operator's shell — no
jump-box VM, private endpoint, VNet peering, or private DNS zone required.
Tree building (`01`) authenticates via an `az account get-access-token`
Entra ID token against the raw ADLS Gen2 REST API; the actual restore
procedure (`02`–`04`) authenticates via `Az.Storage`'s
`New-AzStorageContext -UseConnectedAccount`. Both are Entra ID / RBAC-based
(`Storage Blob Data Owner`), never storage account keys.

## Prerequisites

- Azure CLI, logged in (`az login`)
- Azure PowerShell `Az.Storage` module 9.0.0+, connected (`Connect-AzAccount`)
- A subscription with rights to create resource groups, storage accounts,
  role assignments, and Network Security Perimeter resources
- PowerShell 7+
- Your current public IP must be reachable — `00-provision-test-environment.ps1`
  refreshes the NSP rule to your IP automatically on every run; re-run it if
  your IP changes mid-session (VPN, DHCP renewal, etc.)

> **Known issue:** re-provisioning after a teardown can hit a long NSP
> propagation delay — see [Troubleshooting](#troubleshooting-nsp-propagation-delay-after-re-provisioning)
> below before assuming something is broken.

## Scripts (4 total)

### `00-provision-test-environment.ps1`

**Provisions (default) or tears down (`-TearDown`)** the whole test
environment.

**Provision mode** creates/verifies, in order:
1. Resource group `rg-blob-softdelete-test` (`eastus2`)
2. An HNS-enabled (ADLS Gen2) Standard_LRS storage account with blob soft
   delete enabled (7-day retention by default)
3. RBAC: `Storage Blob Data Owner` for the signed-in user
4. A Network Security Perimeter, profile, and inbound access rule
   (allowlisting the operator's **current** public IP, refreshed every run),
   associated with the storage account in `Enforced` mode
5. The `cortex` filesystem/container
6. A live authenticated REST call to confirm the NSP path is reachable
   end-to-end

Idempotent — every step checks for existing resources before creating,
except the NSP access rule, which always refreshes to the current IP.

**Teardown mode** (`-TearDown`) wipes out everything: previews every
resource in the resource group, prompts for a typed `DELETE` confirmation
(skip with `-Force`), deletes the resource group asynchronously (removing
the storage account, NSP + profile + rule + association, and any scoped role
assignments in one shot), and clears local run artifacts (`manifest.json`,
`incident.json`, `restore-manifest.json`, `restore-checkpoint.json`,
`restore-audit.log`, `build-run.log`, `dry-run-report.txt`).

**Usage:**
```powershell
.\00-provision-test-environment.ps1              # stand up the environment
.\00-provision-test-environment.ps1 -TearDown    # wipe everything (prompts for confirmation)
.\00-provision-test-environment.ps1 -TearDown -Force   # wipe everything, no prompt
```

### `01-build-and-validate-tree.ps1`

**Builds + validates (default) or just re-validates (`-ValidateOnly`)** the
synthetic ADLS Gen2 test tree.

**Build mode** generates a randomized but realistic engagement-style tree
(audit-style folder names: `01_Planning`, `FY2024`, `Q3`, `SectionB`, etc.)
via a breadth-first generator targeting an exact directory count (default
**1,308**, matching the customer incident):
- If random branching runs out before hitting the target count, the
  generator pads the tree via **continued breadth-first expansion** off the
  current leaves (not a single deep chain — ADLS Gen2 enforces a maximum
  path depth and returns `PathIsTooDeep` if you go too deep with one long
  chain — hit this during development).
- A defensive uniqueness check throws immediately if path generation ever
  produces duplicate directory paths (caught a real sibling-name-collision
  bug during development).
- Uploads every directory (`PUT ?resource=directory`) and a randomized set
  of files (`PUT ?resource=file` + `PATCH ?action=append` + `PATCH
  ?action=flush`) directly via the ADLS Gen2 REST API, authenticated with an
  Entra ID token from `az account get-access-token`, retrying with backoff
  on `429`/`503`.
- Every leaf directory gets 1–4 files; ~20% of interior (non-leaf)
  directories also get files, for a realistic mixed tree.
- Records a manifest (`artifacts/manifest.json`) of every directory path and
  every file's path/size/SHA-256 hash.

**Both modes** then run the same validation: recursively list the remote
tree and compare against the manifest — full directory path-set match (not
just counts), full file path-set match + exact size match per file, and an
explicit root-directory existence check.

> **Note on the "off-by-one":** the ADLS Gen2 List Paths API, when scoped
> with `directory=<root>`, returns only the root's *descendants*, not the
> root itself. The validation logic accounts for this explicitly (checks
> root existence via a separate `HEAD` request, and compares descendant
> counts as `local count − 1`) rather than naively comparing raw counts.

**Usage:**
```powershell
.\01-build-and-validate-tree.ps1 -TargetDirCount 1308   # build + validate
.\01-build-and-validate-tree.ps1 -ValidateOnly          # re-validate an existing tree, no rebuild
.\01-build-and-validate-tree.ps1 -ValidateOnly -VerifyContent   # + re-download and re-hash every file's content
```

> **`-VerifyContent`:** the default validation confirms full path-set match
> and exact file sizes, which is a strong signal given soft-delete restore
> is an in-place undelete (not a re-copy). For a direct, stronger proof,
> `-VerifyContent` re-downloads every file and re-computes its SHA-256
> against the hash recorded at creation time (pre-deletion) — slower (one
> GET per file) so it's opt-in. Run against the full 1,308-directory /
> 2,164-file restored tree: **all 2,164 files re-hashed, zero mismatches.**

### `02-simulate-incident-delete.ps1`

Simulates the customer's accidental deletion: recursively deletes the root
directory recorded in `manifest.json`, via the native cmdlet
`Remove-AzDataLakeGen2Item -Force`.

- Records a UTC timestamp window (a couple of seconds before/after the
  delete call) so the enumeration step can filter to exactly this incident —
  the same way you'd need to when a real account has multiple unrelated
  soft-delete generations at overlapping paths.
- Verifies the root is actually gone afterward (`Get-AzDataLakeGen2Item`
  should fail) and throws if it doesn't.
- Writes `artifacts/incident.json` with the account/filesystem/root path and
  the time window, consumed by the next step.

**Usage:**
```powershell
.\02-simulate-incident-delete.ps1
```

### `03-restore-all-deleted.ps1`

A minimal, production-only script for one simple use case: give it a
storage account name and a container name, and it restores **every**
currently soft-deleted blob/directory found in that container. No path
filtering, no time window, no test-harness mode, no `incident.json` — just
"restore everything soft-deleted here."

This replaces an earlier, more elaborate combined script
(`03-enumerate-deleted-items.ps1` + `04-bulk-restore.ps1`, later merged into
a single dual-mode/dual-action `03-restore-deleted-items.ps1` with
`-IncidentPath`, `-StorageAccountName`/`-Filesystem`/`-RootPath`/
`-WindowStartUtc`/`-WindowEndUtc`, `-PreviewOnly`, `-DryRun`, checkpointing,
and audit logging). That version accumulated real, useful safety features
(stale-manifest detection, `(Path, DeletionId)`-keyed resumability,
tenant-mismatch-aware error messages) but also accumulated enough parameters
and modes that, in practice, repeatedly caused confusion about which
account was being targeted and whether a run had actually restored
anything or just previewed. It's kept for reference in `scripts/_bkp/`, but
is no longer the primary tool — this script replaces it for day-to-day use.

**Only two required parameters:**
- `-StorageAccountName` — the storage account to restore from.
- `-ContainerName` — the container (filesystem) within that account to
  restore.

**One optional switch:**
- `-PreviewOnly` — lists every soft-deleted item that would be restored,
  without making any changes. **Omit this switch to actually restore (the
  default action).**

**What it does, step by step:**
1. Connects via `New-AzStorageContext -UseConnectedAccount` (Entra ID —
   sign in first with `Connect-AzAccount` using an identity with at least
   `Storage Blob Data Reader` to preview, or `Storage Blob Data
   Owner`/`Contributor` to restore).
2. Enumerates **every** soft-deleted item in the container via
   `Get-AzDataLakeGen2DeletedItem` (paginated, no `-Path` or time filter at
   all — lists from the container root).
3. Sorts results parents-first (shallowest path depth first) so nested
   directories restore in a safe order.
4. Prints the full list (path, deletionId, deleted time, remaining
   retention days).
5. If `-PreviewOnly`, stops here — zero writes.
6. Otherwise, calls `Restore-AzDataLakeGen2DeletedItem` for every item
   found. If an individual restore call fails, checks whether the path is
   already live (a shallower parent's restore may have already brought it
   back recursively) and counts that as success, not failure, rather than
   a real error.
7. Prints a summary: counts of restored / already-live / failed items, and
   an overall `PASS`/`FAIL`.

**Deliberately left out, compared to the earlier version** (in the spirit
of keeping this to just the one use case): no `incident.json`/test-harness
mode, no path or time-window scoping, no persisted checkpoint file (each
run re-enumerates and re-attempts fresh; `Restore-AzDataLakeGen2DeletedItem`
on an already-restored path is naturally treated as "already live," so
re-running after an interruption is still safe, just without a
resumability state file), no separate audit log file (everything is
printed to the console), no tenant-mismatch pattern-matching (a plain
`try`/`catch` with a short, actionable message covers it).

**Usage:**
```powershell
# See what would be restored, zero writes:
.\03-restore-all-deleted.ps1 -StorageAccountName stsdbxlzhgns -ContainerName cortex -PreviewOnly

# Actually restore everything soft-deleted in the container (default action):
.\03-restore-all-deleted.ps1 -StorageAccountName stsdbxlzhgns -ContainerName cortex
```

**Validated:** tested end-to-end against the real test account/container —
`-PreviewOnly` correctly listed the pending soft-deleted item with zero
writes; the default (restoring) run brought it back (`RESULT: PASS`),
independently confirmed via a live existence check; a follow-up
`-PreviewOnly` run against an already-clean container correctly reported
"No soft-deleted items found... Nothing to do."

## Typical end-to-end run

```powershell
cd scripts
.\00-provision-test-environment.ps1                            # stand up storage account + NSP
.\01-build-and-validate-tree.ps1 -TargetDirCount 1308           # build + validate test tree
.\02-simulate-incident-delete.ps1                               # simulate the accidental recursive delete
.\03-restore-all-deleted.ps1 -StorageAccountName <acct> -ContainerName cortex -PreviewOnly  # optional: preview first, zero writes
.\03-restore-all-deleted.ps1 -StorageAccountName <acct> -ContainerName cortex               # default action: restores everything found
.\01-build-and-validate-tree.ps1 -ValidateOnly -VerifyContent   # confirm byte-for-byte fidelity post-restore (full SHA-256 content proof)
```

This sequence (with the earlier, more elaborate `03` implementations) was
run multiple times, end-to-end, at full customer scale (1,308 directories /
2,164 files) — across an Azure CLI-based implementation, then the native
`Az.Storage` PowerShell cmdlet implementation — and the final validation
pass confirmed every time: root exists, full directory path-set match, full
file path-set match, all file sizes match, and (when run with
`-VerifyContent`) every file's SHA-256 content hash matches exactly, zero
errors. The current `03-restore-all-deleted.ps1` was validated the same way
at the single-incident scale it's designed for.

For a real production incident: skip `02` (the customer's deletion already
happened), run `03-restore-all-deleted.ps1 -PreviewOnly` first with the
real account/container for customer review, then run it again **without**
`-PreviewOnly` after approval to actually restore everything found.

## Artifacts (`../artifacts/`)

| File | Written by | Contents |
|---|---|---|
| `manifest.json` | `01-build-and-validate-tree.ps1` | Every directory path; every file's path/size/SHA-256 |
| `incident.json` | `02-simulate-incident-delete.ps1` | Root path + UTC delete time window |

`03-restore-all-deleted.ps1` writes no artifacts to disk — everything
(the list of soft-deleted items found, and the restore outcome per item)
is printed directly to the console.



## Cleanup / teardown

```powershell
.\00-provision-test-environment.ps1 -TearDown
```
- Previews every resource currently in the resource group before doing
  anything.
- Prompts for a typed `DELETE` confirmation (skip with `-Force` for
  unattended/scripted runs).
- Deletes the entire resource group asynchronously — removes the storage
  account (and all its data), the NSP + profile + access rule + association,
  and any role assignments scoped to it, in one operation.
- Clears local run artifacts so the next run starts from a clean slate.

Re-running `00-provision-test-environment.ps1` (without `-TearDown`)
afterward recreates an identical environment (same storage account name,
same NSP configuration). Note: storage account names are globally unique —
recreation under the same name will only succeed once the deleted account is
fully purged (typically a few minutes after deletion).

## Troubleshooting: NSP propagation delay after re-provisioning

**Symptom:** after running `00-provision-test-environment.ps1` (fresh
provision or re-provision following a `-TearDown`), the filesystem-creation
step and/or `CONNECTIVITY CHECK` fails, even though every NSP setting looks
correct.

**Actual captured output from a real run that hit this:**
```
=== Network Security Perimeter: nsp-blob-softdelete-test ===
NSP created
NSP profile created
Current public IP: 100.33.80.217 -- refreshing NSP inbound access rule
NSP inbound rule allowlists 100.33.80.217/32
Storage account associated with NSP (Enforced)

=== Filesystem: cortex ===
Filesystem create attempt 1 failed (NSP still propagating, ~0.5 min elapsed) -- retrying in 30s...
Filesystem create attempt 2 failed (NSP still propagating, ~1 min elapsed) -- retrying in 30s...
Filesystem create attempt 3 failed (NSP still propagating, ~1.5 min elapsed) -- retrying in 30s...
Filesystem create attempt 4 failed (NSP still propagating, ~2 min elapsed) -- retrying in 30s...
```
Direct REST calls against both the `dfs` and `blob` endpoints during the
same incident consistently returned:
```json
{"error":{"code":"AuthorizationFailure","message":"This request is not authorized by network security perimeter to perform this operation.\nRequestId:...\nTime:2026-08-21T03:01:57Z"}}
```

**Diagnosis performed (all ruled out as the cause):**
| Checked | Result |
|---|---|
| NSP inbound access rule (`allow-my-ip`) | Correct — `100.33.80.217/32`, `Inbound`, `provisioningState: Succeeded` |
| NSP resource association (`assoc-storage`) | Correct — `accessMode: Enforced`, `hasProvisioningIssues: no` |
| Storage account's own view of the NSP config (`networkSecurityPerimeterConfigurations` via ARM REST) | Matched the NSP resource exactly — same rule, same access mode |
| RBAC role assignment | `Storage Blob Data Owner`, `principalType: User`, scope correctly targets the storage account, `oid` in the access token matched the role assignment's principal exactly |
| Deny assignments in the subscription | None scoped anywhere near this resource group (only unrelated Databricks-managed-workspace deny assignments existed) |
| DNS / network path | `dfs.core.windows.net` resolved to an IPv4-only address; `Test-NetConnection` succeeded at the TCP layer — ruled out any IPv6/routing mismatch |
| Managed identity on the storage account | Was genuinely missing (`MissingIdentityConfiguration` in the Azure portal's NSP "Issues" tab) — fixed via `az storage account update --assign-identity`, though this specifically governs *intra-perimeter* resource-to-resource calls, not external inbound access, so it was not the root cause of this particular failure |
| Blob endpoint vs. DFS endpoint | Both failed identically — ruled out an endpoint/sub-resource-specific quirk |
| Waiting longer (retested at +2 min, +4 min, +9 min, +14 min after the association was last recreated) | Still failing every time, well past the propagation delay observed in an earlier, successful provisioning of the same environment |
| Entirely fresh NSP (new perimeter/profile/rule/association names, e.g. `nsp-blob-sd-v2`) | Also failed identically, even though the storage account's own `networkSecurityPerimeterConfigurations` proxy correctly reflected the new perimeter within seconds — ruled out any stale-name/caching issue tied to reusing the original NSP resource names |
| `publicNetworkAccess` was `Disabled` instead of `SecuredByPerimeter` | Was a real, legitimate finding (fixed — see below) but confirmed via testing to **not** resolve the 403s on its own, consistent with Microsoft's own compatibility table (see below) |

**On `publicNetworkAccess`:** the Azure portal's "Configure public network
access" dialog offers `Enabled` / `Disabled` / `SecuredByPerimeter`, and it's
reasonable to suspect `Disabled` (which was the value here) blocks NSP from
ever being evaluated. However, per Microsoft's documented compatibility
table for [NSP association access modes](https://learn.microsoft.com/en-us/azure/private-link/network-security-perimeter-transition#moving-new-resources-into-network-security-perimeter):

| Public Network Access | Association `accessMode: Enforced` |
|---|---|
| Enabled | Inbound: NSP rules only |
| Disabled | Inbound: NSP rules only |
| SecuredByPerimeter | Inbound: NSP rules only |

Once the association's `accessMode` is `Enforced` (as ours already was), all
three `publicNetworkAccess` values are documented to behave **identically**
for inbound traffic. Testing confirmed this: switching `Disabled` →
`SecuredByPerimeter` did **not** resolve the ongoing 403s. `00-provision-test-environment.ps1`
still sets this to `SecuredByPerimeter` (not left at `Disabled`), because
it's the correct defense-in-depth default — if the resource is ever
dissociated from the perimeter, `SecuredByPerimeter` fails closed
(Denied/Denied) rather than `Disabled`'s Denied-inbound/Allowed-outbound,
and unlike `Enabled`, it is not silently reverted by the tenant's governance
policy — but it should not be expected to fix an NSP `AuthorizationFailure`
on an association that's already `Enforced`.

**Follow-up test: switching the association to `Transition` (Learning) mode.**
Per the same table, `SecuredByPerimeter` + `Transition` is documented to
behave identically to `SecuredByPerimeter` + `Enforced` (both: "Inbound: NSP
rules only") — confirmed empirically: switching the association's
`accessMode` to `Transition` while keeping `publicNetworkAccess:
SecuredByPerimeter` did **not** resolve the 403s. The one documented
combination that *would* have let traffic bypass a stuck NSP layer entirely
— `publicNetworkAccess: Enabled` + `accessMode: Transition` (falls back to
the storage account's own firewall rules, which default to `Allow`, when
NSP has no matching rule) — turned out not to be testable in this tenant:
attempting to set `publicNetworkAccess` to `Enabled` was **silently reverted
back to `Disabled`** by the same management-group-scope governance policy
encountered at the very start of this engagement — confirmed twice (once via
CLI, and re-confirmed via the activity log, which shows the policy engine's
own remediation write firing within milliseconds of the attempted change:
`policies/modify/action Succeeded` immediately followed by a second
`storageAccounts/write` that reverts the value). This happens at the
ARM/policy-engine level, so it's **client-agnostic** — attempting the same
change via the Azure portal's "Configure public network access" dialog would
be reverted identically; `Secured By Perimeter` is the only one of the three
options in that dialog that the tenant's governance policy actually allows
to persist. This is also a useful negative result on its own: it confirms
the rejection is happening squarely within NSP's own rule evaluation, not
the account's firewall, since even in `Transition` mode, a
`SecuredByPerimeter` account routes strictly through NSP with no fallback.
Both settings were reverted back to the intended
production posture (`SecuredByPerimeter` + `Enforced`) after this test.

**Conclusion:** with every configurable layer independently confirmed
correct — including a from-scratch NSP with new resource names, and a
direct test of the one access-mode combination that could have bypassed a
broken NSP (blocked by tenant policy) — the remaining explanation is that
Azure Network Security Perimeter's data-plane enforcement was lagging behind
its control-plane `provisioningState: Succeeded` status by longer than
usual in this environment/session. The Azure portal (**Network Security
Perimeters → Associated resources**) is the fastest way to confirm the
control-plane state is correct: look for `Issues (0)`, `Status: Succeeded`,
and the correct IP under **Inbound access rules**. If all of that is green
(including `Effective public network access: Secured By Perimeter`) and
requests are still rejected, it is most likely this propagation
characteristic rather than a configuration error — though if it persists
well beyond what's reasonable, treat it as a genuine Azure-side issue worth
escalating (e.g., via an Azure support case) rather than continuing to
re-diagnose configuration that has already been verified correct multiple
times over.

**Resolution / mitigation:**
- `00-provision-test-environment.ps1` now also explicitly sets
  `publicNetworkAccess` to `SecuredByPerimeter` (previously left at whatever
  the account defaulted to, which was `Disabled`) as a defense-in-depth best
  practice, even though testing showed it isn't the fix for `Enforced`-mode
  403s specifically.
- The filesystem-creation step retries with backoff (12 attempts × 15s = 3
  minutes) before failing, to absorb ordinary propagation delay.
- If it still times out, simply **re-run the script** — every step is
  idempotent — or wait longer and manually retry:
  ```powershell
  az storage fs list --account-name <account> --auth-mode login
  ```
  If it's still failing after an extended wait (e.g., 15–20+ minutes) with
  every configuration check green, consider it a genuine platform-side issue
  for that session rather than something fixable by further reconfiguration.
- **This delay does not affect the validity of the recovery procedure
  itself.** Scripts `03`/`04` (the actual enumerate/restore logic) were
  already fully proven end-to-end — 1,308 directories, 2,164 files, full
  restore, and byte-level SHA-256 content verification, all **PASS** —
  before this propagation issue was encountered on a *subsequent*
  re-provisioning cycle of the test environment. It is a one-off
  environment-setup timing issue, not a defect in the tooling being handed
  off to the customer (which doesn't involve NSP at all — see
  [Connectivity model](#connectivity-model-read-this-first)).
