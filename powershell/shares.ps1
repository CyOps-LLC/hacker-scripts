param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$IP
)

Write-Host "`nEnumerating shares on \\$IP ...`n" -ForegroundColor Cyan

# Run net view to get share list
$netViewOutput = net view "\\$IP" /all 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to enumerate shares on \\$IP" -ForegroundColor Red
    Write-Host ($netViewOutput | Out-String)
    exit 1
}

# Parse share names from net view output
# net view output has a dashed separator line, then share rows like:
#   ShareName       Disk        Some remark
# We skip headers and the separator, grab everything after the dash line until a blank/summary line.

$lines = $netViewOutput | ForEach-Object { "$_" }
$dashIndex = -1

for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^-{5,}') {
        $dashIndex = $i
        break
    }
}

if ($dashIndex -lt 0) {
    Write-Host "Could not parse net view output. Raw output:" -ForegroundColor Yellow
    Write-Host ($netViewOutput | Out-String)
    exit 1
}

$shares = @()

for ($i = $dashIndex + 1; $i -lt $lines.Count; $i++) {
    $line = $lines[$i].TrimEnd()

    # Stop at the summary line ("The command completed successfully.") or blank
    if ([string]::IsNullOrWhiteSpace($line) -or $line -match 'The command completed') {
        break
    }

    # Share name is everything before the first type column (Disk, Print, IPC)
    # net view columns are fixed-width; the share name is the first token before whitespace + type keyword
    if ($line -match '^(.+?)\s{2,}(Disk|Print|IPC)') {
        $shareName = $Matches[1].Trim()
        $shareType = $Matches[2]
        $shares += [PSCustomObject]@{
            Name = $shareName
            Type = $shareType
        }
    }
}

if ($shares.Count -eq 0) {
    Write-Host "No shares found on \\$IP" -ForegroundColor Yellow
    exit 0
}

Write-Host "Found $($shares.Count) share(s). Checking access as $($env:USERDOMAIN)\$($env:USERNAME) ...`n"

$results = @()

foreach ($share in $shares) {
    $uncPath = "\\$IP\$($share.Name)"

    try {
        # Attempt to list the contents of the share
        $null = Get-ChildItem -Path $uncPath -ErrorAction Stop | Select-Object -First 1
        $status = "ACCESS GRANTED"
        $color = "Green"
    }
    catch [System.UnauthorizedAccessException] {
        $status = "ACCESS DENIED"
        $color = "Red"
    }
    catch {
        $msg = $_.Exception.Message
        if ($msg -match 'is not accessible|Access is denied|network path was not found|logon failure') {
            $status = "ACCESS DENIED"
            $color = "Red"
        }
        else {
            $status = "ERROR: $msg"
            $color = "Yellow"
        }
    }

    Write-Host ("{0,-40} {1,-8} {2}" -f $uncPath, "[$($share.Type)]", $status) -ForegroundColor $color

    $results += [PSCustomObject]@{
        Share  = $uncPath
        Type   = $share.Type
        Status = $status
    }
}

Write-Host "`n--- Summary ---"
$granted = ($results | Where-Object { $_.Status -eq "ACCESS GRANTED" }).Count
$denied  = ($results | Where-Object { $_.Status -eq "ACCESS DENIED" }).Count
$errors  = ($results | Where-Object { $_.Status -like "ERROR:*" }).Count
Write-Host "Accessible: $granted  |  Denied: $denied  |  Errors: $errors" -ForegroundColor Cyan
