param (
    [Parameter(Mandatory=$true)]
    [string]$Folder
)

if (-not (Test-Path $Folder)) {
    Write-Host "Folder not found: $Folder"
    Start-Sleep -Seconds 1
    exit 1
}

Write-Host "Changes detected in folder: $Folder"

# Check if running in Windows PowerShell or PowerShell Core
$isWindowsPowerShell = $PSVersionTable.PSEdition -eq 'Desktop'

if ($isWindowsPowerShell) {
    # Windows PowerShell has -Stream parameter on Get-Item
    $blockedFiles = Get-ChildItem -Path $Folder -File -ErrorAction SilentlyContinue | Where-Object {
        (Get-Item $_.FullName -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue)
    }
    
    if ($blockedFiles) {
        $blockedFiles | ForEach-Object {
            Remove-Item -Path $_.FullName -Stream 'Zone.Identifier' -Force
            Write-Host "✓ Unblocked: $($_.FullName)"
        }
    } else {
        Write-Host "No blocked files found."
    }
} else {
    # PowerShell Core - use Unblock-File cmdlet which works cross-platform
    Write-Host "Running in PowerShell Core - Edition: $($PSVersionTable.PSEdition), Version: $($PSVersionTable.PSVersion)"
    
    $allFiles = Get-ChildItem -Path $Folder -File -ErrorAction SilentlyContinue
    Write-Host "Total files found: $($allFiles.Count)"
    
    $blockedFiles = $allFiles | Where-Object {
        $zoneFile = "$($_.FullName):Zone.Identifier"
        $hasZone = Test-Path -LiteralPath $zoneFile -ErrorAction SilentlyContinue
        if ($hasZone) {
            Write-Host "  Found Zone.Identifier on: $($_.Name)"
        }
        $hasZone
    }
    
    if ($blockedFiles) {
        Write-Host "Attempting to unblock $($blockedFiles.Count) file(s)..."
        $blockedFiles | ForEach-Object {
            Write-Host "  Processing: $($_.FullName)"
            try {
                Unblock-File -Path $_.FullName -ErrorAction Stop
                
                # Verify it was removed
                $zoneFile = "$($_.FullName):Zone.Identifier"
                $stillBlocked = Test-Path -LiteralPath $zoneFile -ErrorAction SilentlyContinue
                
                if ($stillBlocked) {
                    Write-Host "  ⚠ WARNING: Zone.Identifier still exists after Unblock-File" -ForegroundColor Yellow
                    Write-Host "  Attempting manual removal via Get-Item..."
                    try {
                        # Try alternative method using .NET
                        $stream = [System.IO.File]::OpenWrite("$($_.FullName):Zone.Identifier")
                        $stream.Close()
                        [System.IO.File]::Delete("$($_.FullName):Zone.Identifier")
                        Write-Host "  ✓ Manually removed Zone.Identifier" -ForegroundColor Green
                    } catch {
                        Write-Host "  ❌ Manual removal also failed: $_" -ForegroundColor Red
                    }
                } else {
                    Write-Host "  ✓ Unblocked: $($_.Name)" -ForegroundColor Green
                }
            } catch {
                Write-Host "  ❌ Error unblocking: $_" -ForegroundColor Red
            }
        }
    } else {
        Write-Host "No blocked files found."
    }
}

Start-Sleep -Seconds 1