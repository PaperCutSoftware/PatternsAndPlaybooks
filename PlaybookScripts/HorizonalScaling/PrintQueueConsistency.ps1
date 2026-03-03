# --- Configuration ---
# Replace with the actual hostnames of your print servers
$serverA = "PrintServer01"
$serverB = "PrintServer02"

# --- Script Body ---
# Get the list of printer names from each server
$printersA = Get-Printer -ComputerName $serverA | Select-Object -ExpandProperty Name
$printersB = Get-Printer -ComputerName $serverB | Select-Object -ExpandProperty Name

# Compare the two lists
$comparison = Compare-Object -ReferenceObject $printersA -DifferenceObject $printersB

# Display the results in a readable format
Write-Host "--- Print Queue Comparison ---"
$comparison | ForEach-Object {
    if ($_.SideIndicator -eq "<=") {
        Write-Host "[QUEUE] '$($_.InputObject)' only exists on $serverA" -ForegroundColor Yellow
    }
    if ($_.SideIndicator -eq "=>") {
        Write-Host "[QUEUE] '$($_.InputObject)' only exists on $serverB" -ForegroundColor Cyan
    }
}
Write-Host "--- Comparison Complete ---"