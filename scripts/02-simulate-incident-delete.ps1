#requires -Version 5.1
#requires -Modules Az.Storage
# Simulates the customer's incident: recursively deletes the root of the
# synthetic test tree (built by 01-build-and-validate-tree-local.ps1) on an
# HNS/soft-delete-enabled account, using the native Az.Storage PowerShell
# cmdlet (Remove-AzDataLakeGen2Item -Force), matching the delete side of the
# documented restore procedure at:
# https://learn.microsoft.com/en-us/azure/storage/blobs/soft-delete-blob-manage#restore-soft-deleted-blobs-and-directories-by-using-powershell
# Records the exact UTC time window of the deletion so later enumeration can
# filter to this specific incident.

param(
    [string]$AccountName  = "stsdbxlzhgns",
    [string]$Filesystem   = "cortex",
    [string]$ManifestPath = "C:\Users\varghesejoji\Desktop\squad-test\blob-softdelete-recovery\artifacts\manifest.json",
    [string]$IncidentPath = "C:\Users\varghesejoji\Desktop\squad-test\blob-softdelete-recovery\artifacts\incident.json"
)

$ErrorActionPreference = "Stop"
$manifestObj = Get-Content $ManifestPath -Raw | ConvertFrom-Json
$rootPath = $manifestObj.RootPath
Write-Output "Simulating accidental recursive delete of: $rootPath"
Write-Output "  (Directories=$($manifestObj.DirCount) Files=$($manifestObj.FileCount))"

# Entra ID (OAuth) storage context -- no account keys, matching the
# key-based-auth-disabled tenant policy this account lives under.
$ctx = New-AzStorageContext -StorageAccountName $AccountName -UseConnectedAccount

$deletedAfterUtc = (Get-Date).ToUniversalTime().AddSeconds(-2).ToString("o")

Remove-AzDataLakeGen2Item -Context $ctx -FileSystem $Filesystem -Path $rootPath -Force

$deletedBeforeUtc = (Get-Date).ToUniversalTime().AddSeconds(2).ToString("o")
Write-Output "Delete call completed. Incident window: $deletedAfterUtc .. $deletedBeforeUtc"

# ---- Verify the root is actually gone ----
$stillExists = $true
try {
    Get-AzDataLakeGen2Item -Context $ctx -FileSystem $Filesystem -Path $rootPath -ErrorAction Stop | Out-Null
} catch {
    $stillExists = $false
}
if ($stillExists) {
    throw "Root path still exists after delete -- simulated incident did not take effect."
}
Write-Output "Confirmed: root path no longer accessible (deleted)."

$incident = [PSCustomObject]@{
    AccountName      = $AccountName
    Filesystem       = $Filesystem
    RootPath         = $rootPath
    DeletedAfterUtc  = $deletedAfterUtc
    DeletedBeforeUtc = $deletedBeforeUtc
    ExpectedDirCount = $manifestObj.DirCount
    ExpectedFileCount = $manifestObj.FileCount
}
$incident | ConvertTo-Json | Out-File -Encoding utf8 $IncidentPath
Write-Output "Incident metadata written to $IncidentPath"
