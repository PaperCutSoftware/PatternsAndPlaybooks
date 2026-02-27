<#
.SYNOPSIS
    Production Serial Load Tester for PaperCut Integrated Scanning.
    Features:
    - Serial Burst Looping (X jobs per Y seconds).
    - PRIORITY: Picks random files from Source Folder if available.
    - Fallback: Uses Custom PDF path if folder is empty.
    - Full Transaction Logging & Device Status.
    - LOGGING: Outputs filename being sent.
#>

# --- 1. CONFIGURATION ---

# PaperCut Server
$serverHost = "" 
$serverPort = 9191
$httpProtocol = "http"

# Device / Vendor
$deviceName = "LoadTest-Scanner" 
$vendorId = "beta"
$authDetails = "8e7f71b5872306506c0d20886d45203b" 

# User
$testUsername = "admin"
$testPassword = "130252"

# Source of Scan Files (HIGHEST PRIORITY)
$scanSourceFolder = "C:\temp\TestScans" 

# Custom PDF (FALLBACK if folder is empty/missing)
$customPdfPath = "C:/Users/damien.white/Desktop/ASCEvolution_MadridBriefing.pdf"

# --- LOAD SETTINGS ---
$scansPerBurst = 45       # How many jobs to send in one batch
$burstIntervalSeconds = 60 # How often to start a new batch (seconds)
$durationMinutes = 60    # Total run time

# --- 2. PREPARATION ---

$scanFileToUse = "$env:TEMP\scan_job_payload.pdf"
$stagingFile = "$env:TEMP\current_scan_job.dat"
$sourceFileList = @()

# Logic: Check Folder -> Check Custom File -> Generate Dummy
if ((Test-Path $scanSourceFolder) -and (Get-ChildItem $scanSourceFolder -File).Count -gt 0) {
    Write-Host "--- Setup: Using Random PDFs from Folder ---" -ForegroundColor Cyan
    Write-Host "Folder: $scanSourceFolder"
    $sourceFileList = Get-ChildItem -Path $scanSourceFolder -File | Select-Object -ExpandProperty FullName
}
elseif (-not [string]::IsNullOrWhiteSpace($customPdfPath) -and (Test-Path $customPdfPath)) {
    Write-Host "--- Setup: Folder empty/missing. Using Custom PDF ---" -ForegroundColor Yellow
    Write-Host "Source: $customPdfPath"
    $sourceFileList = @($customPdfPath)
}
else {
    Write-Host "--- Setup: No sources found. Generating Dummy PDF ---" -ForegroundColor Red
    $pdfContent = "%PDF-1.0`n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj 2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj 3 0 obj<</Type/Page/MediaBox[0 0 3 3]/Parent 2 0 R/Resources<<>>>>endobj`nxref`n0 4`n0000000000 65535 f`n0000000010 00000 n`n0000000060 00000 n`n0000000111 00000 n`ntrailer<</Size 4/Root 1 0 R>>`nstartxref`n190`n%%EOF"
    [System.IO.File]::WriteAllBytes($scanFileToUse, [System.Text.Encoding]::ASCII.GetBytes($pdfContent))
    $sourceFileList = @($scanFileToUse)
}

# --- HELPER FUNCTIONS ---

function Format-Xml {
    param([string]$XmlString)
    try {
        if ([string]::IsNullOrWhiteSpace($XmlString)) { return "" }
        $doc = New-Object System.Xml.XmlDocument
        $doc.LoadXml($XmlString)
        $sb = New-Object System.Text.StringBuilder
        $settings = New-Object System.Xml.XmlWriterSettings
        $settings.Indent = $true
        $settings.IndentChars = "  "
        $writer = [System.Xml.XmlWriter]::Create($sb, $settings)
        $doc.Save($writer)
        $writer.Close()
        return $sb.ToString()
    }
    catch { return $XmlString }
}

function Invoke-XmlRpc {
    param([string]$Url, [string]$MethodName, [string[]]$ParamsXml)
    $pString = $ParamsXml -join ""
    $xml = "<?xml version='1.0'?><methodCall><methodName>$MethodName</methodName><params>$pString</params></methodCall>"
    try {
        $response = Invoke-WebRequest -Uri $Url -Method Post -Body $xml -ContentType "text/xml" -ErrorAction Stop
        return [xml]$response.Content
    } catch {
        Write-Error "XML-RPC Call Failed ($MethodName): $($_.Exception.Message)"
        return $null
    }
}

function New-XmlString { param([string]$s) return "<param><value><string>$s</string></value></param>" }
function New-XmlInt { param([int]$i) return "<param><value><int>$i</int></value></param>" }
function New-XmlDbl { param([double]$d) return "<param><value><double>$d</double></value></param>" }

function New-StatusStruct {
    param([string]$description, [bool]$inUse)
    $inUseInt = if($inUse){1}else{0}
    return @"
<param><value><struct>
  <member><name>status-description</name><value><string>$description</string></value></member>
  <member><name>in-use</name><value><boolean>$inUseInt</boolean></value></member>
  <member><name>in-error</name><value><boolean>0</boolean></value></member>
</struct></value></param>
"@
}

$xmlRpcUrl = "{0}://{1}:{2}/rpc/extdevice/xmlrpc" -f $httpProtocol, $serverHost, $serverPort
$uploadUrl = "{0}://{1}:{2}/rpc/api/rest/device/scan-file/stream" -f $httpProtocol, $serverHost, $serverPort

# --- 3. EXECUTION LOOP ---

$stopTime = (Get-Date).AddMinutes($durationMinutes)
$totalScans = 0
$totalFails = 0

Write-Host "--- Starting BURST SCAN LOAD TEST ---" -ForegroundColor Cyan
Write-Host "  Target:   $serverHost"
Write-Host "  Rate:     $scansPerBurst jobs every $burstIntervalSeconds seconds"
Write-Host "  Duration: $durationMinutes minutes"
Write-Host "--------------------------------------"

try {
    while ((Get-Date) -lt $stopTime) {
        $swBurst = [System.Diagnostics.Stopwatch]::StartNew()
        
        Write-Host "[$([DateTime]::Now.ToString('HH:mm:ss'))] Starting Burst of $scansPerBurst..." -ForegroundColor Cyan

        # --- BURST LOOP ---
        for ($i = 1; $i -le $scansPerBurst; $i++) {
            $totalScans++
            $swJob = [System.Diagnostics.Stopwatch]::StartNew()
            Write-Host "  Job $i/$scansPerBurst : " -NoNewline

            try {
                # 1. Begin Session
                $resp = Invoke-XmlRpc -Url $xmlRpcUrl -MethodName "api.beginSession" -ParamsXml @((New-XmlString $vendorId), (New-XmlString $authDetails), (New-XmlInt 1))
                if ($resp.methodResponse.fault) { throw "Fault: $($resp.methodResponse.fault.value.struct.member.value.string)" }
                
                $sessionId = $null
                $node = $resp.SelectSingleNode("//member[name='sessionId']/value")
                if ($node) { $sessionId = $node.InnerText }
                if (-not $sessionId) { $sessionId = $resp.SelectSingleNode("//methodResponse/params/param/value").InnerText }
                if (-not $sessionId) { throw "No Session ID" }

                # 2. Register Device
                $caps = "<param><value><struct><member><name>scan</name><value><array><data><value><string>TRUE</string></value></data></array></value></member><member><name>scan-paper-size</name><value><array><data><value><string>A4</string></value></data></array></value></member></struct></value></param>"
                $resp = Invoke-XmlRpc -Url $xmlRpcUrl -MethodName "api.registerDeviceWithCapabilities" -ParamsXml @((New-XmlString $sessionId), (New-XmlString $deviceName), (New-XmlString "GENERIC"), $caps)
                $deviceId = $resp.SelectSingleNode("//member[name='deviceId']/value").InnerText

                # Update Status: Ready
                $statusXml = New-StatusStruct -description "Awaiting user login" -inUse $false
                Invoke-XmlRpc -Url $xmlRpcUrl -MethodName "api.updateDeviceStatus" -ParamsXml @((New-XmlString $sessionId), (New-XmlString $deviceId), $statusXml) | Out-Null

                # 3. Auth User
                $resp = Invoke-XmlRpc -Url $xmlRpcUrl -MethodName "api.authenticateUserWithPassword" -ParamsXml @((New-XmlString $sessionId), (New-XmlString $deviceId), (New-XmlString $testUsername), (New-XmlString $testPassword), (New-XmlInt 0))
                if ($resp.SelectSingleNode("//member[name='status']/value").InnerText -ne "SUCCESS") { throw "Auth Failed" }

                # Update Status: In Use
                $statusXml = New-StatusStruct -description "User '$testUsername' logged in" -inUse $true
                Invoke-XmlRpc -Url $xmlRpcUrl -MethodName "api.updateDeviceStatus" -ParamsXml @((New-XmlString $sessionId), (New-XmlString $deviceId), $statusXml) | Out-Null

                # 3a. Begin Transaction
                $resp = Invoke-XmlRpc -Url $xmlRpcUrl -MethodName "api.beginDeviceTransaction" -ParamsXml @((New-XmlString $sessionId), (New-XmlString $deviceId), (New-XmlString $testUsername), (New-XmlString ""))
                $transactionId = $resp.SelectSingleNode("//member[name='transactionId']/value").InnerText
                if (-not $transactionId) { $transactionId = $resp.SelectSingleNode("//methodResponse/params/param/value/string").InnerText }

                # 4. Get Scan Actions
                $resp = Invoke-XmlRpc -Url $xmlRpcUrl -MethodName "api.getIntegratedScanActions" -ParamsXml @((New-XmlString $sessionId), (New-XmlString $deviceId), (New-XmlString $testUsername), (New-XmlString ""))
                $actions = $resp.SelectNodes("//member[name='scanActions']/value/array/data/value/struct")
                $actionId = $null; $actionLabel = "Scan"
                if ($actions) {
                    foreach ($a in $actions) {
                        if ($a.SelectSingleNode("member[name='isEnabled']/value/boolean").InnerText -eq "1") {
                            $actionId = $a.SelectSingleNode("member[name='id']/value").InnerText
                            $actionLabel = $a.SelectSingleNode("member[name='label']/value").InnerText
                            break
                        }
                    }
                }
                if (-not $actionId) { throw "No Enabled Actions" }

                # 5. Start Job
                $resp = Invoke-XmlRpc -Url $xmlRpcUrl -MethodName "api.getIntegratedScanActionDetails" -ParamsXml @((New-XmlString $sessionId), (New-XmlString $deviceId), (New-XmlString $testUsername), (New-XmlString ""), (New-XmlString $actionId))
                $actionXml = $resp.SelectSingleNode("//member[name='scanAction']/value").InnerXml
                $resp = Invoke-XmlRpc -Url $xmlRpcUrl -MethodName "api.integratedScanJobStarted" -ParamsXml @((New-XmlString $sessionId), (New-XmlString $deviceId), (New-XmlString $testUsername), (New-XmlString ""), (New-XmlString $actionId), "<param><value>$actionXml</value></param>")
                $jobId = $resp.SelectSingleNode("//member[name='scanJobId']/value").InnerText

                # 6. Upload File (Random Selection from our prepared list)
                $fileToSend = $sourceFileList | Get-Random
                
                # Copy to staging to avoid file locks
                Copy-Item -Path $fileToSend -Destination $stagingFile -Force
                $fileNameLog = Split-Path $fileToSend -Leaf
                Write-Host "Sending '$fileNameLog' ... " -NoNewline

                # Upload using simple URL construction
                $fullUpUrl = "$uploadUrl/$deviceId/$jobId"
                Invoke-WebRequest -Uri $fullUpUrl -Method Post -InFile $stagingFile -ContentType "application/octet-stream" | Out-Null

                # 7. Complete Job (Simple 5 params)
                $resp = Invoke-XmlRpc -Url $xmlRpcUrl -MethodName "api.integratedScanJobCompleted" -ParamsXml @((New-XmlString $sessionId), (New-XmlString $deviceId), (New-XmlString $jobId), (New-XmlString "SUCCESS"), (New-XmlString "Load Test"))

                # 8. Complete Transaction
                $scanStruct = "<value><array><data><value><string>SCAN</string></value><value><string>$actionLabel</string></value><value><int>1</int></value></data></array></value>"
                $jobArr = "<param><value><array><data>$scanStruct</data></array></value></param>"
                $resp = Invoke-XmlRpc -Url $xmlRpcUrl -MethodName "api.completeDeviceTransaction" -ParamsXml @((New-XmlString $sessionId), (New-XmlString $deviceId), (New-XmlString $transactionId), (New-XmlDbl -1.0), $jobArr, (New-XmlString ""), (New-XmlString ""))

                # 9. Cleanup & Reset Status
                $statusXml = New-StatusStruct -description "Awaiting user login" -inUse $false
                Invoke-XmlRpc -Url $xmlRpcUrl -MethodName "api.updateDeviceStatus" -ParamsXml @((New-XmlString $sessionId), (New-XmlString $deviceId), $statusXml) | Out-Null
                
                # No EndSession call

                Write-Host "OK ($($swJob.Elapsed.TotalSeconds.ToString("N2"))s)" -ForegroundColor Green

            } catch {
                $totalFails++
                Write-Host "FAIL: $_" -ForegroundColor Red
            }
        }
        # --- END BURST LOOP ---

        $elapsed = $swBurst.Elapsed.TotalSeconds
        Write-Host "Burst Complete in $($elapsed.ToString("N2"))s." -ForegroundColor Gray
        
        if ($elapsed -lt $burstIntervalSeconds) {
            $sleepTime = $burstIntervalSeconds - $elapsed
            Write-Host "Sleeping for $($sleepTime.ToString("N2"))s..."
            Start-Sleep -Seconds $sleepTime
        } else {
            Write-Warning "Burst took longer than interval! System may be saturated."
        }
    }
}
finally {
    Remove-Item $stagingFile -ErrorAction SilentlyContinue
    Remove-Item $scanFileToUse -ErrorAction SilentlyContinue
    Write-Host "--------------------------------------"
    Write-Host "Test Complete."
    Write-Host "Total Scans: $totalScans"
    Write-Host "Total Fails: $totalFails"
}
