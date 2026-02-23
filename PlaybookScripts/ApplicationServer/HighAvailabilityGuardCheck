 # --- Configuration ---
# The hostname or IP address of your SQL Server.
$sqlServer = "192.168.1.100"

# The SQL Authenticated username and password
$username = "papercut"
$password = "PaperCut"

# The name of the database and target table.
$database = "papercut"
$tableName = "tbl_ha_active_server"

# The query to retrieve the active server record.
$query = "SELECT TOP 1 * FROM $tableName ORDER BY 1 DESC;"

# --- Script Body ---
try {
    Write-Host "Connecting to $sqlServer to query table '$tableName'..." -ForegroundColor Cyan
    
    # Executing the query using SQL Authentication
    $result = Invoke-SqlCmd -ServerInstance $sqlServer -Database $database -Query $query -Username $username -Password $password -ErrorAction Stop

    if ($result) {
        Write-Host "✅ Success! Data found in '$tableName':" -ForegroundColor Green
        
        # Display the data in a clean table format
        $result | Format-Table -AutoSize
        
        Write-Host "Active server record retrieved successfully." -ForegroundColor Green
    } else {
        Write-Host "❓ Connection successful, but the table '$tableName' appears to be empty." -ForegroundColor Yellow
    }
}
catch {
    Write-Host "❌ Error connecting to SQL Server or executing query. Details below:" -ForegroundColor Red
    Write-Host $_.Exception.Message
} 
