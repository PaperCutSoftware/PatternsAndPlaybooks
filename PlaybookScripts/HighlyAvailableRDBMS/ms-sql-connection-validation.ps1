# --- Configuration ---
# The hostname or IP address of your SQL Server.
$sqlServer = ""

# The SQL Authenticated username and password
$username = "papercut"
$password = "papercut"

# The name of a database on that server (e.g., 'master').
$database = "papercut_03"

# The query to get the database's collation.
$query = "SELECT DATABASEPROPERTYEX('$database', 'Collation') AS DatabaseCollation;"

# --- Script Body ---
try {
    Write-Host "Connecting to $sqlServer to check database '$database'..."
    # We connect to the 'master' database to run the query against our target database.
    $result = Invoke-SqlCmd -ServerInstance $sqlServer -Database "master" -Query $query -Username $username -Password $password
    
    if ($result) {
        $collation = $result.DatabaseCollation
        Write-Host "✅ Success! The collation for '$database' is: '$collation'" -ForegroundColor Green
        
        if ($collation -like "*_UTF8") {
            Write-Host "This collation is UTF-8 compliant." -ForegroundColor Green
        } else {
            Write-Host "This collation is NOT UTF-8 compliant." -ForegroundColor Yellow
        }
    } else {
        Write-Host "❓ Query returned no result. Check server/database names and permissions." -ForegroundColor Yellow
    }
}
catch {
    Write-Host "❌ Error connecting to SQL Server. Please check the details below:" -ForegroundColor Red
    Write-Host $_.Exception.Message
}
