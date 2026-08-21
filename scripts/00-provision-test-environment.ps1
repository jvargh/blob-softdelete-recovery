#requires -Version 5.1
<#
.SYNOPSIS
    Provisions (default) OR tears down (-TearDown) the blob soft-delete
    recovery TEST environment.

.DESCRIPTION
    PROVISION MODE (default):
    Idempotent-as-possible script that reproduces every provisioning step
    used to stand up the at-scale test harness for the blob-softdelete-recovery
    engagement. Safe to re-run: resource "create" calls are ARM PUT semantics
    (no-op if unchanged), and steps that are NOT naturally idempotent (role
    assignments) are explicitly existence-checked first.

    Produces:
      - Resource group rg-blob-softdelete-test (eastus2)
      - HNS-enabled (ADLS Gen2) Storage Account with blob soft delete (7-day retention)
      - "cortex" filesystem/container inside it
      - RBAC: Storage Blob Data Owner for the signed-in user (data-plane
        access; this tenant blocks storage account key-based auth)
      - A Network Security Perimeter (NSP) associated with the storage
        account in Enforced mode, with an inbound access rule allowlisting
        the operator's current public IP

    Connectivity model:
      Tenant governance enforces a management-group-scope policy (Modify
      effect) that forces publicNetworkAccess=Disabled on every storage
      account -- attempting to flip it to Enabled gets silently reverted.
      NSP is the way around this that stays policy-compliant: the storage
      account itself remains publicNetworkAccess=Disabled, but the NSP
      association's inbound access rule explicitly allowlists this
      operator's public IP, letting authenticated requests from that IP
      reach the account while all other public traffic stays blocked.
      This lets automation run directly from this operator's shell -- no
      jump-box VM, private endpoint, VNet, or private DNS zone required.

    TEARDOWN MODE (-TearDown):
    Wipes out everything created above:
      - Deletes the resource group (and everything in it: storage account,
        NSP + profile + access rule + association, role assignments scoped
        to it)
      - Clears local run artifacts (manifest.json, incident.json,
        restore-manifest.json, restore-checkpoint.json, restore-audit.log,
        build-run.log) so a fresh run starts with a clean slate
    This is destructive and irreversible (soft-deleted data inside the test
    account is also purged once the resource group itself is deleted -- the
    account's soft-delete retention policy does NOT protect against the
    account/resource-group being deleted outright, only against individual
    blob/directory deletes within a live account). Prompts for a typed
    "DELETE" confirmation unless -Force is passed.

.NOTES
    Re-provisioning after teardown: storage account names are globally
    unique; recreation under the same name only succeeds once the deleted
    account is fully purged (a few minutes after deletion).
#>

param(
    [string]$ResourceGroup      = "rg-blob-softdelete-test",
    [string]$Location           = "eastus2",
    [string]$StorageAccountName = "stsdbxlzhgns",
    [string]$FilesystemName     = "cortex",
    [int]   $SoftDeleteRetentionDays = 7,

    # NSP
    [string]$NspName            = "nsp-sd-fresh",
    [string]$NspProfileName     = "profFresh",
    [string]$NspRuleName        = "ruleFresh",

    [string]$ArtifactsPath = "C:\Users\varghesejoji\Desktop\squad-test\blob-softdelete-recovery\artifacts",

    [switch]$TearDown,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
function Write-Step($msg) { Write-Output "`n=== $msg ===" }

# =============================================================================
# TEARDOWN MODE
# =============================================================================
if ($TearDown) {
    $rgExists = az group exists -n $ResourceGroup -o tsv
    if ($rgExists -eq "true") {
        Write-Output "Resource group '$ResourceGroup' found. Resources inside it:"
        az resource list -g $ResourceGroup --query "[].{name:name, type:type}" -o table
    } else {
        Write-Output "Resource group '$ResourceGroup' does not exist (already cleaned up)."
    }

    if (-not $Force) {
        $confirmation = Read-Host "Type 'DELETE' to permanently remove resource group '$ResourceGroup' and all local artifacts"
        if ($confirmation -ne "DELETE") {
            Write-Output "Aborted -- no changes made."
            exit 1
        }
    }

    if ($rgExists -eq "true") {
        Write-Output "Deleting resource group '$ResourceGroup' (async, no-wait)..."
        az group delete -n $ResourceGroup --yes --no-wait
        Write-Output "Delete requested. Track completion with: az group show -n $ResourceGroup"
    } else {
        Write-Output "Skipping resource group deletion -- nothing to delete."
    }

    $artifactFiles = @(
        "manifest.json", "incident.json", "restore-manifest.json",
        "restore-checkpoint.json", "restore-audit.log", "build-run.log"
    )
    Write-Output "`nClearing local artifacts in $ArtifactsPath ..."
    foreach ($f in $artifactFiles) {
        $full = Join-Path $ArtifactsPath $f
        if (Test-Path $full) {
            Remove-Item $full -Force
            Write-Output "  Removed: $f"
        }
    }

    Write-Output "`nCleanup complete. Re-run without -TearDown to rebuild the environment from scratch."
    return
}

# =============================================================================
# PROVISION MODE (default)
# =============================================================================
$sub = (az account show --query id -o tsv)
Write-Output "Subscription: $sub"

Write-Step "Resource group: $ResourceGroup"
az group create -n $ResourceGroup -l $Location -o none
Write-Output "OK"

Write-Step "Storage account: $StorageAccountName (HNS, soft delete $SoftDeleteRetentionDays days, SecuredByPerimeter from creation)"
$saExists = az storage account show -n $StorageAccountName -g $ResourceGroup --query name -o tsv 2>$null
if (-not $saExists) {
    # Setting --public-network-access SecuredByPerimeter at CREATE time (not
    # retrofitted afterward) is the sequence that was empirically confirmed
    # to work cleanly on the first attempt -- see README.md Troubleshooting.
    az storage account create `
        -n $StorageAccountName -g $ResourceGroup -l $Location `
        --sku Standard_LRS --kind StorageV2 --hns true --min-tls-version TLS1_2 `
        --public-network-access SecuredByPerimeter -o none
    Write-Output "Storage account created"
} else {
    Write-Output "Storage account already exists"
}
az storage account blob-service-properties update `
    -n $StorageAccountName -g $ResourceGroup `
    --enable-delete-retention true --delete-retention-days $SoftDeleteRetentionDays -o none
$hns = az storage account show -n $StorageAccountName -g $ResourceGroup --query isHnsEnabled -o tsv
Write-Output "Confirmed isHnsEnabled=$hns"

Write-Step "RBAC: Storage Blob Data Owner for signed-in user"
$saId = "/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.Storage/storageAccounts/$StorageAccountName"
$myObjId = (az ad signed-in-user show --query id -o tsv)
$existingUserRole = az role assignment list --assignee $myObjId --scope $saId --role "Storage Blob Data Owner" --query "[0].id" -o tsv
if (-not $existingUserRole) {
    az role assignment create --assignee-object-id $myObjId --assignee-principal-type User `
        --role "Storage Blob Data Owner" --scope $saId -o none
    Write-Output "Role assignment created for user $myObjId"
} else {
    Write-Output "Role assignment already present for user $myObjId"
}

Write-Step "Managed identity (required for NSP intra-perimeter communication)"
$identity = az storage account show -n $StorageAccountName -g $ResourceGroup --query identity -o json | ConvertFrom-Json
if (-not $identity -or -not $identity.principalId) {
    az storage account update -n $StorageAccountName -g $ResourceGroup --assign-identity -o none
    Write-Output "Managed identity assigned"
} else {
    Write-Output "Managed identity already assigned (principalId=$($identity.principalId))"
}

Write-Step "Network Security Perimeter: $NspName"
if (-not (az network perimeter show -g $ResourceGroup -n $NspName --query name -o tsv 2>$null)) {
    az network perimeter create -g $ResourceGroup -n $NspName -l $Location -o none
    Write-Output "NSP created"
}
if (-not (az network perimeter profile show -g $ResourceGroup --perimeter-name $NspName -n $NspProfileName --query name -o tsv 2>$null)) {
    az network perimeter profile create -g $ResourceGroup --perimeter-name $NspName -n $NspProfileName -o none
    Write-Output "NSP profile created"
}

$myIp = (Invoke-RestMethod -Uri "https://api.ipify.org?format=json").ip
Write-Output "Current public IP: $myIp -- refreshing NSP inbound access rule"
az network perimeter profile access-rule create -g $ResourceGroup --perimeter-name $NspName `
    --profile-name $NspProfileName -n $NspRuleName --direction Inbound --address-prefixes "$myIp/32" -o none
Write-Output "NSP inbound rule allowlists $myIp/32"

$profileId = "/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.Network/networkSecurityPerimeters/$NspName/profiles/$NspProfileName"
if (-not (az network perimeter association show -g $ResourceGroup --perimeter-name $NspName -n assoc-storage --query name -o tsv 2>$null)) {
    az network perimeter association create -g $ResourceGroup --perimeter-name $NspName -n assoc-storage `
        --private-link-resource "id=$saId" --profile "id=$profileId" --access-mode Enforced -o none
    Write-Output "Storage account associated with NSP (Enforced)"
} else {
    Write-Output "Storage account already associated with NSP"
}

# ---------------------------------------------------------------------------
# Defensive guard: ensure publicNetworkAccess is SecuredByPerimeter (normally
# already set at account creation above; this only matters if re-running
# against a pre-existing account that predates that fix). Do NOT use
# "Enabled" here -- this tenant's governance policy silently reverts it back
# to "Disabled" (confirmed via testing; see README.md Troubleshooting).
# ---------------------------------------------------------------------------
$currentAccess = az storage account show -n $StorageAccountName -g $ResourceGroup --query publicNetworkAccess -o tsv
if ($currentAccess -ne "SecuredByPerimeter") {
    Write-Step "Public network access: SecuredByPerimeter"
    az storage account update -n $StorageAccountName -g $ResourceGroup --public-network-access SecuredByPerimeter -o none
    Write-Output "publicNetworkAccess changed: $currentAccess -> SecuredByPerimeter"
}

Write-Step "Filesystem: $FilesystemName"
# With publicNetworkAccess correctly set to SecuredByPerimeter (above), NSP
# access-rule evaluation should now genuinely govern requests, and access
# should work within a short delay. A modest retry budget is still kept as a
# defensive measure for residual NSP data-plane propagation lag (observed to
# occasionally take a few minutes after an association change), but this is
# no longer expected to take anywhere near as long as it did before this
# publicNetworkAccess fix was identified and applied.
$maxAttempts = 12
$retryDelaySeconds = 15
$fsReady = $false
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    $fsExists = az storage fs exists --account-name $StorageAccountName -n $FilesystemName --auth-mode login --query exists -o tsv 2>$null
    if ($fsExists -eq "true") {
        Write-Output "Filesystem already exists"
        $fsReady = $true
        break
    }
    az storage fs create -n $FilesystemName --account-name $StorageAccountName --auth-mode login -o none 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Output "Filesystem created (attempt $attempt)"
        $fsReady = $true
        break
    }
    $elapsedSec = $attempt * $retryDelaySeconds
    Write-Output "Filesystem create attempt $attempt failed (NSP/publicNetworkAccess still propagating, ~${elapsedSec}s elapsed) -- retrying in ${retryDelaySeconds}s..."
    Start-Sleep -Seconds $retryDelaySeconds
}
if (-not $fsReady) {
    throw "Failed to create filesystem '$FilesystemName' after $maxAttempts attempts (~$($maxAttempts * $retryDelaySeconds)s). Check that publicNetworkAccess is 'SecuredByPerimeter' (not 'Disabled') and that the NSP access rule/association are correct -- see README.md Troubleshooting section. Re-run this script (it's idempotent) if those look correct; it may just need another minute or two."
}

Write-Step "Validation"
az storage account show -n $StorageAccountName -g $ResourceGroup `
    --query "{name:name, hns:isHnsEnabled, publicNetworkAccess:publicNetworkAccess, sku:sku.name, location:location}" -o json
az storage account blob-service-properties show -n $StorageAccountName -g $ResourceGroup --query deleteRetentionPolicy -o json
$token = (az account get-access-token --resource https://storage.azure.com/ --query accessToken -o tsv)
$headers = @{ Authorization = "Bearer $token"; "x-ms-version" = "2021-06-08" }
$connectivityOk = $false
for ($attempt = 1; $attempt -le 5; $attempt++) {
    try {
        Invoke-WebRequest -Uri "https://$StorageAccountName.dfs.core.windows.net/$FilesystemName?resource=filesystem&recursive=false" `
            -Method GET -Headers $headers -UseBasicParsing -TimeoutSec 20 | Out-Null
        Write-Output "CONNECTIVITY CHECK: PASS (direct public path via NSP is reachable and authenticated)"
        $connectivityOk = $true
        break
    } catch {
        if ($attempt -lt 5) { Start-Sleep -Seconds 15 }
    }
}
if (-not $connectivityOk) {
    Write-Output "CONNECTIVITY CHECK: FAIL (NSP may still be propagating -- this does not necessarily mean provisioning failed; re-run any subsequent script and it will retry the request)"
}

Write-Output "`nProvisioning complete."
