#requires -Version 5.1
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
    Builds and validates (default) OR just re-validates (-ValidateOnly) the
    synthetic ADLS Gen2 test tree.

.DESCRIPTION
    BUILD MODE (default):
    Runs LOCALLY (direct public access to the test storage account via
    Network Security Perimeter allowlisting this host's IP). Builds a synthetic
    ADLS Gen2 directory tree mirroring the customer incident's scale/depth
    (1308 directories, mixed file counts/sizes), uploads it via the ADLS Gen2
    REST API using an az CLI-issued Entra ID token, records a manifest, then
    validates the upload byte-for-byte against that manifest.

    VALIDATE-ONLY MODE (-ValidateOnly):
    Skips generation/upload entirely and re-validates an already-built tree
    against its existing manifest.json -- useful for re-checking fidelity
    after a restore, without waiting for a full multi-thousand-call rebuild.

    Validation (both modes) does a full path-set comparison (not just counts):
      - Recursively lists the remote tree and compares every directory path
        and every file path/size against the manifest
      - Explicitly checks root-directory existence via a separate HEAD call,
        since the ADLS Gen2 List Paths API scoped with `directory=<root>`
        returns only the root's DESCENDANTS, not the root itself
#>

param(
    [int]$TargetDirCount = 1308,
    [string]$AccountName = "stsdbxlzhgns",
    [string]$Filesystem = "cortex",
    [string]$ManifestPath = "C:\Users\varghesejoji\Desktop\squad-test\blob-softdelete-recovery\artifacts\manifest.json",
    [switch]$ValidateOnly,
    [switch]$VerifyContent
)

$ErrorActionPreference = "Stop"
$workDir = Split-Path -Parent $ManifestPath
New-Item -ItemType Directory -Force -Path $workDir | Out-Null

$dfsHost = "$AccountName.dfs.core.windows.net"
$apiVersion = "2021-06-08"

$token = (az account get-access-token --resource https://storage.azure.com/ --query accessToken -o tsv)
if (-not $token) { throw "Failed to acquire access token" }
Write-Output "Acquired token via az CLI"

Add-Type -AssemblyName System.Net.Http
$handler = New-Object System.Net.Http.HttpClientHandler
$client = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds(100)
$client.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", $token)
$client.DefaultRequestHeaders.Add("x-ms-version", $apiVersion)

function Invoke-DfsRequest {
    param([string]$Method, [string]$Uri, [byte[]]$Body, [string]$ContentType = "application/octet-stream")
    $maxRetries = 6
    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::new($Method), $Uri)
            if ($null -ne $Body) {
                $content = New-Object System.Net.Http.ByteArrayContent(,$Body)
                $content.Headers.ContentLength = $Body.Length
                $content.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue($ContentType)
                $req.Content = $content
            }
            $resp = $client.SendAsync($req).Result
            if ([int]$resp.StatusCode -eq 429 -or [int]$resp.StatusCode -eq 503) {
                Start-Sleep -Milliseconds (250 * $attempt)
                continue
            }
            if (-not $resp.IsSuccessStatusCode) {
                $errBody = $resp.Content.ReadAsStringAsync().Result
                throw "HTTP $([int]$resp.StatusCode) on $Method $Uri : $errBody"
            }
            return $resp
        } catch {
            if ($attempt -eq $maxRetries) { throw }
            Start-Sleep -Milliseconds (350 * $attempt)
        }
    }
}

function New-RemoteDirectory {
    param([string]$Path)
    $uri = "https://$dfsHost/$Filesystem/$Path`?resource=directory"
    Invoke-DfsRequest -Method "PUT" -Uri $uri | Out-Null
}

function New-RemoteFile {
    param([string]$Path, [byte[]]$Bytes)
    $base = "https://$dfsHost/$Filesystem/$Path"
    Invoke-DfsRequest -Method "PUT" -Uri "$base`?resource=file" | Out-Null
    if ($Bytes.Length -gt 0) {
        Invoke-DfsRequest -Method "PATCH" -Uri "$base`?action=append&position=0" -Body $Bytes | Out-Null
    }
    Invoke-DfsRequest -Method "PATCH" -Uri "$base`?action=flush&position=$($Bytes.Length)" | Out-Null
}

$dirErrors = 0
$fileErrors = 0

if ($ValidateOnly) {
    # ---- Load an already-built tree's manifest instead of generating one ----
    $manifestObj = Get-Content $ManifestPath -Raw | ConvertFrom-Json
    $rootPath = $manifestObj.RootPath
    $allDirs = [string[]]$manifestObj.Directories
    $manifest = $manifestObj.Files
    Write-Output "Loaded manifest: RootPath=$rootPath DirCount=$($allDirs.Count) FileCount=$($manifest.Count)"
} else {
    # ---- 1. Generate a realistic engagement-style tree (BFS, variable branching) ----
    $rnd = New-Object System.Random(20260819)
    $clientId = [guid]::NewGuid().ToString()
    $engagementId = [guid]::NewGuid().ToString()
    $rootPath = "prd/cortex/filesystem/US/${clientId}_CONTOSO_RETAIL_INC/Engagement/$engagementId"

    $level1 = @("01_Planning","02_RiskAssessment","03_ControlsTesting","04_SubstantiveTesting","05_TrialBalance",
                "06_Adjustments","07_Confirmations","08_Correspondence","09_PriorYearWorkpapers","10_FinancialStatements",
                "11_TaxWorkpapers","12_PBCItems","13_FieldworkNotes","14_ReviewNotes","15_Support","16_Admin")
    $yearPool = @("FY2023","FY2024","FY2025")
    $quarterPool = @("Q1","Q2","Q3","Q4")
    $sectionPool = @("SectionA","SectionB","SectionC","SectionD","SectionE")
    $leafPool = @("Item","Detail","Note","Reconciliation","Schedule")

    function Get-ChildName {
        param([int]$Depth, [int]$Index)
        # NOTE: Index is always appended so that siblings under the same parent
        # can never collide on name (pool arrays are shorter than max branching,
        # e.g. yearPool has 3 entries but a parent can have up to 4 children).
        switch ($Depth) {
            0 { return $level1[$Index % $level1.Count] + "_" + $Index }
            1 { return $yearPool[$Index % $yearPool.Count] + "_" + $Index }
            2 { return $quarterPool[$Index % $quarterPool.Count] + "_" + $Index }
            3 { return $sectionPool[$Index % $sectionPool.Count] + "_" + $Index }
            default { return $leafPool[$Index % $leafPool.Count] + "_" + $Index }
        }
    }

    $allDirs = New-Object System.Collections.Generic.List[string]
    $allDirs.Add($rootPath)
    $queue = New-Object System.Collections.Generic.Queue[object]
    $queue.Enqueue(@{ Path = $rootPath; Depth = 0 })
    $maxDepth = 7

    while ($queue.Count -gt 0 -and $allDirs.Count -lt $TargetDirCount) {
        $node = $queue.Dequeue()
        if ($node.Depth -ge $maxDepth) { continue }
        $remaining = $TargetDirCount - $allDirs.Count
        if ($remaining -le 0) { break }
        $want = $rnd.Next(1, 5)
        $numChildren = [Math]::Min($want, $remaining)
        for ($i = 0; $i -lt $numChildren; $i++) {
            $childName = Get-ChildName -Depth $node.Depth -Index $i
            $childPath = "$($node.Path)/$childName"
            $allDirs.Add($childPath)
            $queue.Enqueue(@{ Path = $childPath; Depth = $node.Depth + 1 })
            if ($allDirs.Count -ge $TargetDirCount) { break }
        }
    }

    if ($allDirs.Count -lt $TargetDirCount) {
        # BFS queue can dry up before hitting the target if random branching (and
        # the depth cap) undershoot. Pad via continued breadth-first expansion
        # off the current leaves (NOT a single deep chain -- ADLS Gen2 enforces a
        # maximum directory path depth and returns "PathIsTooDeep" if exceeded).
        Write-Output "BFS undershot target ($($allDirs.Count) of $TargetDirCount) -- padding via continued breadth-first expansion"
        $hasChildTemp = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($d in $allDirs) {
            $idx = $d.LastIndexOf('/')
            if ($idx -gt 0) { [void]$hasChildTemp.Add($d.Substring(0, $idx)) }
        }
        $paddingQueue = New-Object System.Collections.Generic.Queue[object]
        foreach ($d in $allDirs) {
            if (-not $hasChildTemp.Contains($d)) {
                $paddingQueue.Enqueue(@{ Path = $d })
            }
        }
        $padIndex = 0
        while ($allDirs.Count -lt $TargetDirCount -and $paddingQueue.Count -gt 0) {
            $node = $paddingQueue.Dequeue()
            $remaining = $TargetDirCount - $allDirs.Count
            $numChildren = [Math]::Min($rnd.Next(1, 4), $remaining)
            for ($i = 0; $i -lt $numChildren; $i++) {
                $childPath = "$($node.Path)/Overflow_$padIndex"
                $padIndex++
                $allDirs.Add($childPath)
                $paddingQueue.Enqueue(@{ Path = $childPath })
                if ($allDirs.Count -ge $TargetDirCount) { break }
            }
        }
    }

    Write-Output "Generated directory tree: $($allDirs.Count) directories (target $TargetDirCount)"

    $uniqueDirCount = ($allDirs | Select-Object -Unique).Count
    if ($uniqueDirCount -ne $allDirs.Count) {
        throw "Path generation produced duplicate directory paths: $($allDirs.Count) entries but only $uniqueDirCount unique. Fix Get-ChildName before proceeding."
    }

    $hasChild = New-Object System.Collections.Generic.HashSet[string]
    foreach ($d in $allDirs) {
        $idx = $d.LastIndexOf('/')
        if ($idx -gt 0) {
            $parent = $d.Substring(0, $idx)
            [void]$hasChild.Add($parent)
        }
    }
    $leaves = $allDirs | Where-Object { -not $hasChild.Contains($_) }
    Write-Output "Leaf directories (will receive files): $($leaves.Count)"

    # ---- 2. Create directories remotely ----
    $i = 0
    foreach ($d in $allDirs) {
        $i++
        try { New-RemoteDirectory -Path $d } catch { $dirErrors++; Write-Output "DIR-ERROR [$d]: $($_.Exception.Message)" }
        if ($i % 200 -eq 0) { Write-Output "  ...created $i / $($allDirs.Count) directories" }
    }
    Write-Output "Directory creation complete. Errors: $dirErrors"

    # ---- 3. Create files (all leaves + ~20% of interior dirs get 1-4 files) ----
    $manifest = New-Object System.Collections.Generic.List[object]
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $fileCount = 0

    $interiorSample = $allDirs | Where-Object { $hasChild.Contains($_) } | Where-Object { $rnd.NextDouble() -lt 0.20 }
    $dirsGettingFiles = @($leaves) + @($interiorSample)

    foreach ($d in $dirsGettingFiles) {
        $numFiles = $rnd.Next(1, 5)
        for ($f = 0; $f -lt $numFiles; $f++) {
            $ext = @(".pdf",".xlsx",".docx",".txt")[$rnd.Next(0,4)]
            $fname = "File_$($f)_$([guid]::NewGuid().ToString('N').Substring(0,8))$ext"
            $fpath = "$d/$fname"
            $size = $rnd.Next(300, 15000)
            $bytes = New-Object byte[] $size
            $rnd.NextBytes($bytes)
            try {
                New-RemoteFile -Path $fpath -Bytes $bytes
                $hash = [System.BitConverter]::ToString($sha256.ComputeHash($bytes)).Replace("-","").ToLower()
                $manifest.Add([PSCustomObject]@{ Path = $fpath; Size = $size; Sha256 = $hash })
                $fileCount++
                if ($fileCount % 200 -eq 0) { Write-Output "  ...created $fileCount files" }
            } catch {
                $fileErrors++
                Write-Output "FILE-ERROR [$fpath]: $($_.Exception.Message)"
            }
        }
    }
    Write-Output "File creation complete. Files: $fileCount  Errors: $fileErrors"

    # ---- 4. Persist manifest + tree metadata to disk for later phases ----
    $manifestObj = [PSCustomObject]@{
        RootPath       = $rootPath
        Filesystem     = $Filesystem
        AccountName    = $AccountName
        GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        DirCount       = $allDirs.Count
        FileCount      = $fileCount
        Directories    = $allDirs
        Files          = $manifest
    }
    $manifestObj | ConvertTo-Json -Depth 6 -Compress | Out-File -Encoding utf8 $ManifestPath
    Write-Output "Manifest written to $ManifestPath"
}

# ---- Validation pass (both modes): recursively list remote paths, compare ----
$remoteDirs = New-Object System.Collections.Generic.List[string]
$remoteFiles = [System.Collections.Generic.Dictionary[string,long]]::new()
$continuation = $null
do {
    $listUri = "https://$dfsHost/$Filesystem`?resource=filesystem&recursive=true&directory=$([uri]::EscapeDataString($rootPath))&maxResults=5000"
    if ($continuation) { $listUri += "&continuation=$([uri]::EscapeDataString($continuation))" }
    $resp = Invoke-DfsRequest -Method "GET" -Uri $listUri
    $json = $resp.Content.ReadAsStringAsync().Result | ConvertFrom-Json
    foreach ($p in $json.paths) {
        if ($p.isDirectory -eq $true -or $p.isDirectory -eq "true") {
            $remoteDirs.Add($p.name)
        } else {
            $remoteFiles[$p.name] = [long]$p.contentLength
        }
    }
    $continuation = $null
    if ($resp.Headers.Contains("x-ms-continuation")) {
        $continuation = $resp.Headers.GetValues("x-ms-continuation") | Select-Object -First 1
    }
} while ($continuation)

Write-Output "REMOTE COUNT: directories=$($remoteDirs.Count) files=$($remoteFiles.Count)"
Write-Output "LOCAL  COUNT: directories=$($allDirs.Count) files=$($manifest.Count)"

# NOTE: the List Paths API scoped with `directory=<root>` returns only
# DESCENDANTS of the root, not the root directory itself. So the expected
# remote count is (local directories - 1), plus we explicitly verify the
# root exists via a separate GetProperties (HEAD) call.
$rootHeadUri = "https://$dfsHost/$Filesystem/$rootPath"
$rootExists = $true
try {
    Invoke-DfsRequest -Method "HEAD" -Uri $rootHeadUri | Out-Null
} catch {
    $rootExists = $false
    Write-Output "ROOT DIRECTORY MISSING: $rootPath -- $($_.Exception.Message)"
}

$expectedDescendantDirs = $allDirs.Count - 1
$dirCountMatch = ($remoteDirs.Count -eq $expectedDescendantDirs) -and $rootExists
$fileCountMatch = ($remoteFiles.Count -eq $manifest.Count)

$remoteDirSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$remoteDirs)
$localDescendantDirs = $allDirs | Select-Object -Skip 1
$missingDirs = 0
foreach ($d in $localDescendantDirs) {
    if (-not $remoteDirSet.Contains($d)) {
        $missingDirs++
        Write-Output "MISSING DIRECTORY: $d"
    }
}
$localDirSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$allDirs)
$extraDirs = 0
foreach ($d in $remoteDirs) {
    if (-not $localDirSet.Contains($d)) {
        $extraDirs++
        Write-Output "UNEXPECTED EXTRA DIRECTORY: $d"
    }
}

$sizeMismatches = 0
foreach ($m in $manifest) {
    if (-not $remoteFiles.ContainsKey($m.Path)) {
        $sizeMismatches++
        Write-Output "MISSING FILE: $($m.Path)"
    } elseif ($remoteFiles[$m.Path] -ne $m.Size) {
        $sizeMismatches++
        Write-Output "SIZE MISMATCH: $($m.Path) local=$($m.Size) remote=$($remoteFiles[$m.Path])"
    }
}

# ---- Optional: true content verification -- downloads every file and
# re-computes its SHA-256, comparing against the hash recorded at creation
# time (pre-deletion). This is a stronger, direct proof of byte-for-byte
# fidelity than path+size matching alone (which relies on the fact that
# soft-delete restore is an in-place undelete, not a re-copy, as its
# correctness argument). Slower at scale (one GET per file) so it's opt-in.
$hashMismatches = 0
$hashChecked = 0
if ($VerifyContent) {
    Write-Output "`n=== CONTENT VERIFICATION (downloading + re-hashing every file) ==="
    $sha256Verify = [System.Security.Cryptography.SHA256]::Create()
    foreach ($m in $manifest) {
        if (-not $remoteFiles.ContainsKey($m.Path)) { continue }  # already reported as MISSING FILE above
        try {
            $resp = Invoke-DfsRequest -Method "GET" -Uri "https://$dfsHost/$Filesystem/$($m.Path)"
            $bytes = $resp.Content.ReadAsByteArrayAsync().Result
            $hash = [System.BitConverter]::ToString($sha256Verify.ComputeHash($bytes)).Replace("-","").ToLower()
            $hashChecked++
            if ($hash -ne $m.Sha256) {
                $hashMismatches++
                Write-Output "HASH MISMATCH: $($m.Path) local=$($m.Sha256) remote=$hash"
            }
        } catch {
            $hashMismatches++
            Write-Output "HASH CHECK FAILED (download error): $($m.Path) -- $($_.Exception.Message)"
        }
        if ($hashChecked % 200 -eq 0) { Write-Output "  ...verified $hashChecked / $($manifest.Count) file hashes" }
    }
    Write-Output "Content verification complete. Checked=$hashChecked  HashMismatches=$hashMismatches"
}

Write-Output "=== VALIDATION SUMMARY ==="
Write-Output "RootExists=$rootExists  DirCountMatch=$dirCountMatch  FileCountMatch=$fileCountMatch  MissingDirs=$missingDirs  ExtraDirs=$extraDirs  SizeMismatches=$sizeMismatches  DirErrors=$dirErrors  FileErrors=$fileErrors  ContentVerified=$VerifyContent  HashChecked=$hashChecked  HashMismatches=$hashMismatches"
if ($dirCountMatch -and $fileCountMatch -and $missingDirs -eq 0 -and $extraDirs -eq 0 -and $sizeMismatches -eq 0 -and $dirErrors -eq 0 -and $fileErrors -eq 0 -and $hashMismatches -eq 0) {
    if ($VerifyContent) {
        Write-Output "RESULT: PASS - remote tree matches local manifest (counts + full path set + file sizes + SHA-256 content hashes)."
    } else {
        Write-Output "RESULT: PASS - remote tree matches local manifest (counts + full path set + file sizes). Re-run with -VerifyContent for full byte-level hash proof."
    }
} else {
    Write-Output "RESULT: FAIL - see mismatches above."
}
Write-Output "ROOT_PATH=$rootPath"
