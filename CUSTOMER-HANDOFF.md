# Customer Handoff — Soft-Delete Recovery Runbook

**Incident:** Accidental recursive deletion of a deep engagement subdirectory
(and ~1,308 nested subdirectories) in storage account
`auditlakeaapsameprddl`, container `cortex`, between **17:40–17:50 UTC on
8/19/2026**. Soft delete is enabled on the account. See
[hints.txt](hints.txt) for full incident details.

**Deleted path:**
```
prd/cortex/filesystem/US/942b77c5-6fff-4f42-a031-57aa6c21a15e_GROCERY OUTLET_ INC/Engagement/5802dbfe-08cf-4cba-ac20-cf1b215eb94c
```

**Recovery method:** the documented, Microsoft-supported PowerShell
procedure for restoring soft-deleted blobs and directories in an ADLS Gen2
(hierarchical namespace) account:
https://learn.microsoft.com/en-us/azure/storage/blobs/soft-delete-blob-manage#restore-soft-deleted-blobs-and-directories-by-using-powershell

This procedure — and the single script that implements it,
`03-restore-deleted-items.ps1` — was validated end-to-end against a
purpose-built test environment matching this incident's exact scale (1,308
directories, 2,164 files, same nesting depth) before being handed off. See
[README.md](README.md) for full test harness details, including the exact
script sequence used and the audit logs (`artifacts/restore-audit.log`,
`artifacts/restore-checkpoint.json`) proving a clean, byte-for-byte restore
was completed against that test tree.

**Note on "byte-for-byte, point-in-time" recovery:** soft-delete restore is
an *in-place undelete* of the original blob/directory data — it is not a
copy or a snapshot promotion. As long as nothing has been written to the
same path since the deletion, the restored data is, by construction,
identical to what existed at the moment of deletion. This was confirmed
empirically: the test harness recorded a SHA-256 hash and exact byte size
for every file before deletion, then verified an exact match for every file
and every directory path after restore, with zero discrepancies.

---

## What you need

- **Azure PowerShell**, `Az.Storage` module version **9.0.0 or later**
  (`Get-AzDataLakeGen2DeletedItem` / `Restore-AzDataLakeGen2DeletedItem` are
  GA as of this version — no preview module required).
  ```powershell
  Get-Module -ListAvailable Az.Storage | Select-Object Name, Version
  # If missing or older than 9.0.0:
  Install-Module Az.Storage -MinimumVersion 9.0.0 -Scope CurrentUser
  ```
- **Only one script from this handoff is needed** — `03-restore-deleted-items.ps1`.
  The other scripts (`00`, `01`, `02`) are test-harness-only and not required
  for the actual production recovery.
- **Access:** Entra ID identity with at least **Storage Blob Data Reader**
  on `auditlakeaapsameprddl` to run the preview step; **Storage Blob Data
  Owner** or **Storage Blob Data Contributor** to run the actual restore.
  Sign in with `Connect-AzAccount` before running this script.

---

## Pre-flight checklist

Confirm all of these before running anything:

- [ ] **Remaining retention window** — soft-deleted items are permanently
      purged once the retention period expires. Check now:
      ```powershell
      Get-AzStorageBlobServiceProperty -ResourceGroupName <rg> -StorageAccountName auditlakeaapsameprddl |
        Select-Object -ExpandProperty DeleteRetentionPolicy
      ```
      The dry-run report (below) also surfaces the remaining days on each
      matched soft-delete record — treat this as the hard deadline.
- [ ] **RBAC role** confirmed on the account (see above).
- [ ] **No renames** have occurred on the parent path since the deletion.
      Renaming a directory disconnects any soft-deleted children from being
      listed or restored — if this happened, the path must be renamed back
      to its original name first (see the
      [Microsoft doc](https://learn.microsoft.com/en-us/azure/storage/blobs/soft-delete-blob-manage#view-deleted-blobs-and-directories)
      for details).
- [ ] **Nothing has been re-created** at the deleted path since the
      incident — if a new blob/directory now exists at that exact path, the
      old soft-deleted version's restore behavior may differ (versioning
      edge case); confirm the path is currently empty/non-existent before
      proceeding.

---

## Step-by-step recovery

> ⚠️ **IMPORTANT: bare invocation of this script performs a LIVE RESTORE by
> default.** Unlike a typical "safe by default" tool, running
> `.\03-restore-deleted-items.ps1` with no flags does not just preview — it
> immediately restores. Always use `-PreviewOnly` for Step 1 below.

### 1. Preview (read-only, makes zero changes)

```powershell
.\03-restore-deleted-items.ps1 -PreviewOnly
```

This uses the incident's actual values as defaults (account, path, and the
17:40–17:50 UTC window) — no parameters needed unless something has changed.
It produces:
- **`artifacts/dry-run-report.txt`** — human-readable summary: how many
  soft-delete records matched, the earliest retention deadline among them,
  and the exact list of paths/deletionIds that would be restored.
- **`artifacts/restore-manifest.json`** — the same information in
  machine-readable form, for reference/audit.

> **Expect to see just 1 matched record, not 1,308.** Testing showed that a
> single recursive directory delete produces **one** soft-delete record at
> the directory root, and restoring that one record recursively restores
> the entire subtree underneath it (validated against an identically-shaped
> 1,308-directory/2,164-file tree). Seeing 1 record here is the expected,
> successful outcome — not a sign something was missed. If you instead see
> several records, that just means the original deletion happened as
> several separate operations; the restore step below handles that shape
> identically.

**Review `dry-run-report.txt` and get sign-off before proceeding to step 2.**

### 2. Restore

```powershell
# Optional final preview immediately before committing (still zero writes,
# but shows exactly what will be attempted, respecting resumability state):
.\03-restore-deleted-items.ps1 -DryRun

# The actual restore -- run WITHOUT any preview flag (this is the default action):
.\03-restore-deleted-items.ps1
```

- Restores parents before children automatically (safe ordering).
- **Resumable** — if this is interrupted for any reason (network blip,
  session timeout), just re-run `.\03-restore-deleted-items.ps1` again; it
  re-checks the account's current soft-delete state fresh every time and
  checkpoints progress in `artifacts/restore-checkpoint.json`, so it will
  not redo or fail on anything already restored.
- Every outcome is logged with a timestamp to `artifacts/restore-audit.log`.

### 3. Post-restore validation

- [ ] Confirm the summary line at the end of the restore run reads
      `RESULT: PASS`.
- [ ] Spot-check in the Azure portal: navigate to the original path and
      confirm the directory and a sample of subdirectories/files are
      visible and browsable again.
- [ ] Recursively count restored directories/files and compare against
      what was expected (~1,308 directories):
      ```powershell
      $ctx = New-AzStorageContext -StorageAccountName auditlakeaapsameprddl -UseConnectedAccount
      $items = Get-AzDataLakeGen2ChildItem -Context $ctx -FileSystem cortex `
          -Path "prd/cortex/filesystem/US/942b77c5-6fff-4f42-a031-57aa6c21a15e_GROCERY OUTLET_ INC/Engagement/5802dbfe-08cf-4cba-ac20-cf1b215eb94c" `
          -Recurse
      ($items | Where-Object { $_.IsDirectory }).Count   # directory count
      ($items | Where-Object { -not $_.IsDirectory }).Count   # file count
      ```
- [ ] Review `artifacts/restore-audit.log` for any `FAILED` lines — if any
      appear, re-run `.\03-restore-deleted-items.ps1` (default action is
      restore, resumable, and will retry only what's outstanding).

> **On the "byte-for-byte" guarantee for your specific files:** in the test
> harness, we went a step further than count/size checks — every one of the
> 2,164 test files was re-downloaded and re-hashed (SHA-256) after restore
> and compared against a hash recorded *before* deletion, with **zero
> mismatches**. This directly proves the underlying Azure mechanism
> (`Restore-AzDataLakeGen2DeletedItem`) performs a true in-place undelete,
> not a lossy copy. For your actual production files, there's no
> pre-deletion hash manifest to compare against (that requires having
> hashed the files *before* the accidental deletion, which wasn't done here
> since this wasn't a planned event) — so validation of your real data
> relies on the count/path checks above plus the proven mechanism. If you
> have independent checksums from backup/DLP tooling for any of these
> files, comparing those post-restore would close that last gap completely.

---

## Recurrence-prevention recommendations

To reduce the chance of, or blast radius from, a similar accidental deletion
in the future:

1. **Increase the soft-delete retention window.** Confirm the current
   retention period and consider extending it (Microsoft recommends a
   minimum of 7 days; consider 14–30 days for high-value paths like
   engagement data) to widen the recovery window if a deletion isn't
   noticed immediately.
2. **Enable blob versioning** in addition to soft delete, for point-in-time
   recovery of individual blob content changes (not just deletes) —
   protects against accidental overwrites, not only deletes.
3. **Restrict delete permissions via RBAC.** Review who/what has `Storage
   Blob Data Owner` or `Storage Blob Data Contributor` on this account.
   Consider scoping broad delete permissions down to a smaller group, and
   granting most day-to-day users/service principals only `Storage Blob
   Data Reader` or a custom role without delete rights.
4. **Add an Azure Policy guardrail** (e.g., a deny/audit policy on
   `Microsoft.Storage/storageAccounts/blobServices/containers/blobs/delete`
   for specific containers or resource groups, or requiring soft delete +
   minimum retention to be enabled tenant-wide) to prevent this
   configuration from ever being turned off, and to catch high-volume
   delete operations for review.
5. **Consider immutability policies / legal hold** on critical, rarely
   modified engagement data once finalized — this blocks deletion entirely
   for the immutability period, at the cost of also blocking legitimate
   edits during that window.
6. **Add alerting** on high-volume delete operations (e.g., an Azure Monitor
   alert on a spike in `blobServices` delete transactions, or a Log
   Analytics query on `StorageBlobLogs` for delete operations exceeding a
   threshold in a short window) so an accidental bulk delete is caught and
   escalated within minutes rather than being discovered later.
7. **Document and rehearse this runbook** periodically (e.g., during a
   game-day exercise against a disposable test account, following the same
   pattern as `00`–`02` in this repo) so recovery is fast and confident the
   next time it's needed, rather than being worked out under pressure
   during an active incident.
