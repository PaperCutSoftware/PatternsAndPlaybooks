# --- 0. PRE - CONFIGURATION ---
# You will need the PaperCut LPD Service installed on the machine hosting the print queues. You will also need 
# the LPR Port Monitor feature added also for lpd.exe

# --- 1. CONFIGURATION ---
$lpdServerIP = ""
$lpdQueueName = "Find-Me"

# --- Load Configuration ---
$jobsPerBurst = 15
$burstIntervalSeconds = 3
$durationMinutes = 20

# --- NEW SETTING ---
# $true = Spread jobs evenly across the interval (Smooth load)
# $false = Fire all jobs instantly at start of interval (Shock load)
$evenlySpaceJobs = $true

# --- 2. PREPARATION ---
$jobCounter = 0
$totalJobsSent = 0
$stopTime = (Get-Date).AddMinutes($durationMinutes)

# Calculate sub-interval sleep time if spacing is enabled
$interJobSleepMs = 0
if ($evenlySpaceJobs) {
    # E.g. 2 seconds * 1000 / 15 jobs = 133ms between jobs
    $interJobSleepMs = [math]::Floor(($burstIntervalSeconds * 1000) / $jobsPerBurst)
}

Write-Host "--- Starting ROGUE LPD Load Test ---" -ForegroundColor Green
Write-Host "  Target:  $lpdServerIP : $lpdQueueName"
Write-Host "  Rate:    $($jobsPerBurst * (60 / $burstIntervalSeconds)) jobs/minute"
Write-Host "  Spacing: $(if($evenlySpaceJobs){"Evenly Spaced (${interJobSleepMs}ms delay)"}else{"Burst Mode (Instant)"})"
Write-Host "----------------------------------"

# --- 3. EXECUTION LOOP ---

$scriptBlock = {
    param($server, $queue)
    try {
        # 1. Connect to LPD Port 515
        $client = New-Object System.Net.Sockets.TcpClient
        $client.Connect($server, 515)
        $stream = $client.GetStream()
        $writer = New-Object System.IO.BinaryWriter($stream)
        $reader = New-Object System.IO.BinaryReader($stream)
        $send = { param($str) $writer.Write([System.Text.Encoding]::ASCII.GetBytes($str)) }
        
        # 2. Send Receive Job Command
        $writer.Write([byte]2)
        $send.Invoke("$queue`n")
        if ($reader.ReadByte() -ne 0) { throw "Queue rejected connection" }

        # 3. Send Control File
        $ctrlContent = "HWindows`nP$($env:USERNAME)`nNprint_job.txt`n"
        $ctrlSize = $ctrlContent.Length
        $writer.Write([byte]2)
        $send.Invoke("$ctrlSize cfA001Rogue`n")
        if ($reader.ReadByte() -ne 0) { throw "Control file rejected" }
        $send.Invoke($ctrlContent)
        $writer.Write([byte]0)
        if ($reader.ReadByte() -ne 0) { throw "Control file data rejected" }

        # 4. Send Data File
        $dataContent = "Rogue LPD load test job."
        $dataSize = $dataContent.Length
        $writer.Write([byte]3)
        $send.Invoke("$dataSize dfA001Rogue`n")
        if ($reader.ReadByte() -ne 0) { throw "Data file rejected" }
        $send.Invoke($dataContent)
        $writer.Write([byte]0)
        if ($reader.ReadByte() -ne 0) { throw "Data file data rejected" }

        $client.Close()
    }
    catch { throw "Rogue LPD Failed: $_" }
}

try {
    while ((Get-Date) -lt $stopTime) {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        
        if (-not $evenlySpaceJobs) {
            Write-Host "[$([System.DateTime]::Now.ToString('HH:mm:ss'))] Sending burst..."
        }

        # Loop through the number of jobs for this interval
        1..$jobsPerBurst | ForEach-Object {
            
            # Fire the job in a background thread
            Start-ThreadJob -ScriptBlock $scriptBlock -ArgumentList ($lpdServerIP, $lpdQueueName)
            
            # If spacing is enabled, we wait here before firing the next one
            if ($evenlySpaceJobs) {
                Start-Sleep -Milliseconds $interJobSleepMs
            }
        }
        
        $totalJobsSent += $jobsPerBurst
        
        # Cleanup threads
        Get-Job | Where-Object { $_.State -eq 'Completed' -or $_.State -eq 'Failed' } | Remove-Job
        
        # Wait for the remainder of the interval (to keep the total rate accurate)
        $elapsed = $stopwatch.Elapsed.TotalSeconds
        if ($elapsed -lt $burstIntervalSeconds) {
            Start-Sleep -Seconds ($burstIntervalSeconds - $elapsed)
        }
    }
}
finally {
    Write-Host "----------------------------------"
    Get-Job | Remove-Job -ErrorAction SilentlyContinue
    Write-Host "Done. Total jobs sent: $totalJobsSent"
}
