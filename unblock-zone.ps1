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

$blockedFiles = Get-ChildItem -Path $Folder -File -ErrorAction SilentlyContinue | Where-Object {
    (Get-Item $_.FullName -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue)
}

if ($blockedFiles) {
    $blockedFiles | ForEach-Object {
        Remove-Item -Path $_.FullName -Stream 'Zone.Identifier' -Force
        Write-Host "Unblocked: $($_.FullName)"
    }
} else {
    Write-Host "No blocked files found."
}

Start-Sleep -Seconds 1