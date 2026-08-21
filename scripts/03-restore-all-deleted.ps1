#requires -Version 5.1
#requires -Modules Az.Storage
# ==============================================================================
# DISCLAIMER: Provided "AS IS", without warranty of any kind, express or
# implied, including but not limited to warranties of merchantability,
# fitness for a particular purpose, and non-infringement. Use at your own
# risk. Review this script fully and test it in a non-production environment
# before running it against any account containing data you care about. The
# author(s) accept no liability for any data loss, downtime, cost, or other
# damage arising from its use.
# ==============================================================================
<#
.SYNOPSIS
    Restores ALL soft-deleted items in a storage account container.

.DESCRIPTION
    Minimal, production-only script for one simple use case: give it a
    storage account name and a container name, and it restores every
    currently soft-deleted blob/directory found in that container. No path
    filtering, no time window, no test-harness mode, no incident.json --
    just "restore everything soft-deleted here."

    Uses the documented, Microsoft-supported procedure:
    https://learn.microsoft.com/en-us/azure/storage/blobs/soft-delete-blob-manage#restore-soft-deleted-blobs-and-directories-by-using-powershell
    via the native Az.Storage cmdlets Get-AzDataLakeGen2DeletedItem and
    Restore-AzDataLakeGen2DeletedItem (requires Az.Storage 9.0.0+, GA, no
    preview module needed). Authenticates via
    New-AzStorageContext -UseConnectedAccount (Entra ID) -- sign in first
    with Connect-AzAccount using an identity with at least Storage Blob Data
    Reader (to preview) or Storage Blob Data Owner/Contributor (to restore)
    on the target account.

.PARAMETER StorageAccountName
    The storage account to restore from.

.PARAMETER ContainerName
    The container (filesystem) within that account to restore.

.PARAMETER PreviewOnly
    List every soft-deleted item that would be restored, without making any
    changes. Omit this switch to actually restore (default action).

.EXAMPLE
    .\restore-all-deleted.ps1 -StorageAccountName mystorageacct -ContainerName mycontainer -PreviewOnly

.EXAMPLE
    .\restore-all-deleted.ps1 -StorageAccountName mystorageacct -ContainerName mycontainer
#>

param(
    [Parameter(Mandatory = $true)] [string]$StorageAccountName,
    [Parameter(Mandatory = $true)] [string]$ContainerName,
    [switch]$PreviewOnly
)

$ErrorActionPreference = "Stop"

Write-Output "Storage account : $StorageAccountName"
Write-Output "Container       : $ContainerName"
Write-Output "Mode            : $(if ($PreviewOnly) { 'PREVIEW ONLY (no changes)' } else { 'RESTORE (this WILL make changes)' })"
Write-Output ""

$ctx = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount

# ---- Enumerate every soft-deleted item in the container (no path/time filter, paginated) ----
Write-Output "Enumerating all soft-deleted items in '$ContainerName'..."
$allItems = New-Object System.Collections.Generic.List[object]
$token = $null
try {
    do {
        if ($token) {
            $page = Get-AzDataLakeGen2DeletedItem -Context $ctx -FileSystem $ContainerName -MaxCount 5000 -ContinuationToken $token -ErrorAction Stop
        } else {
            $page = Get-AzDataLakeGen2DeletedItem -Context $ctx -FileSystem $ContainerName -MaxCount 5000 -ErrorAction Stop
        }
        foreach ($i in $page) { $allItems.Add($i) }
        $token = $page.ContinuationToken | Select-Object -Last 1
    } while ($token)
} catch {
    Write-Output "ERROR: $($_.Exception.Message)"
    Write-Output ""
    Write-Output "Check: are you signed in (Connect-AzAccount) with an identity in the correct"
    Write-Output "Entra tenant, with Storage Blob Data Reader/Owner on '$StorageAccountName'?"
    exit 1
}

if ($allItems.Count -eq 0) {
    Write-Output "No soft-deleted items found in container '$ContainerName'. Nothing to do."
    exit 0
}

# Sort parents-first (shallowest path depth first) so nested directories
# restore in a safe order.
$sorted = $allItems | Sort-Object { ($_.Path -split '/').Count }, Path

Write-Output ""
Write-Output "Found $($sorted.Count) soft-deleted item(s):"
$sorted | ForEach-Object { Write-Output "  $($_.Path)  (deletionId=$($_.DeletionId), deleted=$($_.DeletedOn), retention=$($_.RemainingRetentionDays)d)" }
Write-Output ""

if ($PreviewOnly) {
    Write-Output "PREVIEW ONLY -- no changes made. Re-run without -PreviewOnly to restore everything listed above."
    exit 0
}

# ---- Restore every item found above ----
Write-Output "Restoring..."
$restored = 0
$alreadyLive = 0
$failed = 0
foreach ($item in $sorted) {
    try {
        Restore-AzDataLakeGen2DeletedItem -Context $ctx -FileSystem $ContainerName -Path $item.Path -DeletionId $item.DeletionId -Confirm:$false -ErrorAction Stop
        $restored++
        Write-Output "  RESTORED: $($item.Path)"
    } catch {
        # A shallower parent restored in this same run may have already
        # brought this child back recursively -- treat "already live" as
        # success, not failure.
        $isLive = $true
        try { Get-AzDataLakeGen2Item -Context $ctx -FileSystem $ContainerName -Path $item.Path -ErrorAction Stop | Out-Null } catch { $isLive = $false }
        if ($isLive) {
            $alreadyLive++
            Write-Output "  ALREADY LIVE (restored via parent): $($item.Path)"
        } else {
            $failed++
            Write-Output "  FAILED: $($item.Path) -- $($_.Exception.Message)"
        }
    }
}

Write-Output ""
Write-Output "=== SUMMARY ==="
Write-Output "Restored: $restored  AlreadyLive: $alreadyLive  Failed: $failed  Total: $($sorted.Count)"
if ($failed -eq 0) {
    Write-Output "RESULT: PASS"
} else {
    Write-Output "RESULT: FAIL - re-run this script to retry the failed item(s)."
}
