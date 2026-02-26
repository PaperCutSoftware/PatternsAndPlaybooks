# --- 1. CONFIGURATION ---

# The hostname or IP of your PaperCut Application Server
$serverHost = ""
$serverPort = 9191 # Default web port

# --- Config for Step 1: Authenticate Release Station ---
$releaseStationID = "Test-Station-1"    # The "Station Name"
$authDetails = "beta"        # The "Password"
$releaseStationType = "API"
$protocolVersion = 3

# --- Config for Step 2: Authenticate User ---
$cardID = "123456789"
$enteredPIN = ""
$stationRequiresPIN = $false
$unusedBoolean = $false
$stationSelfAssociationEnabled = $false

# --- Config for Step 3: Get Held Jobs ---
$isReleaseStationManager = $false
$includeDeniedJobs = $false
$locale = "" # Use default locale

# --- Config for Step 4: Release Jobs ---
$releaseCap = 20 # Our "Smart Cap" (as per our discussion)

# --- 2. HELPER FUNCTION ---

function Invoke-PaperCutApi {
    param(
        [string]$xmlPayload
    )
    
    $endpoint = "http://$($serverHost):$($serverPort)/rpc/release/xmlrpc"
    $headers = @{"Content-Type" = "text/xml"}

    try {
        $response = Invoke-WebRequest -Uri $endpoint -Method Post -Body $xmlPayload -Headers $headers -ErrorAction Stop
        $responseXml = [xml]$response.Content
        
        if ($responseXml.methodResponse.fault) {
            Write-Host "❌ API ERROR: The server returned a fault." -ForegroundColor Red
            $faultString = $responseXml.methodResponse.fault.value.struct.member | Where-Object { $_.name.Trim() -eq 'faultString' } | Select-Object -ExpandProperty value
            if ($faultString) {
                Write-Host "   Reason: $faultString"
            } else {
                Write-Host "   Raw Fault Response:"
                Write-Host ($responseXml.methodResponse.fault.OuterXml) -ForegroundColor Yellow
            }
            return $null
        }
        return $responseXml
    }
    catch {
        Write-Host "❌ FATAL ERROR: Failed to send request to $endpoint." -ForegroundColor Red
        Write-Host $_.Exception.Message
        return $null
    }
}

# --- 3. WORKFLOW ---

# --- Step 1: Authenticate the Release Station ---
Write-Host "--- Step 1: Authenticating Release Station '$releaseStationID'..."
$authStationPayload = @"
<?xml version="1.0"?>
<methodCall>
  <methodName>releaseStation.authenticateReleaseStation</methodName>
  <params>
    <param><value><string>$([System.Security.SecurityElement]::Escape($releaseStationID))</string></value></param>
    <param><value><string>$([System.Security.SecurityElement]::Escape($authDetails))</string></value></param>
    <param><value><string>$([System.Security.SecurityElement]::Escape($releaseStationType))</string></value></param>
    <param><value><int>$($protocolVersion)</int></value></param>
  </params>
</methodCall>
"@
$authResponse = Invoke-PaperCutApi -xmlPayload $authStationPayload
if (-not $authResponse) { Write-Host "Stopping script."; return }

$xpathQuery = "//member[name/text()[normalize-space()='authToken']]/value"
$authTokenNode = Select-Xml -Xml $authResponse -XPath $xpathQuery | Select-Object -ExpandProperty Node
$authToken = $authTokenNode.'#text'
if (-not $authToken) {
    Write-Host "❌ ERROR: Authentication was successful but could not parse authToken from response:"
    $authResponse.OuterXml | Write-Host
    return
}
Write-Host "✅ Station authenticated. Received temporary authToken: $authToken" -ForegroundColor Green


# --- Step 2: Authenticate the User with Card ---
Write-Host ""
Write-Host "--- Step 2: Authenticating Card ID '$cardID'..."
$xmlPin = $(if ($stationRequiresPIN) { "<boolean>1</boolean>" } else { "<boolean>0</boolean>" })
$xmlUnused = $(if ($unusedBoolean) { "<boolean>1</boolean>" } else { "<boolean>0</boolean>" })
$xmlSelfAssoc = $(if ($stationSelfAssociationEnabled) { "<boolean>1</boolean>" } else { "<boolean>0</boolean>" })
$authUserPayload = @"
<?xml version="1.0"?>
<methodCall>
  <methodName>releaseStation.authenticateUserWithCardNo</methodName>
  <params>
    <param><value><string>$($authToken)</string></value></param>
    <param><value><string>$($releaseStationID)</string></value></param>
    <param><value><string>$($cardID)</string></value></param>
    <param><value><string>$($enteredPIN)</string></value></param>
    <param><value>$($xmlPin)</value></param>
    <param><value>$($xmlUnused)</value></param>
    <param><value>$($xmlSelfAssoc)</value></param>
  </params>
</methodCall>
"@
$userResponse = Invoke-PaperCutApi -xmlPayload $authUserPayload
if (-not $userResponse) { Write-Host "Stopping script."; return }

$userStruct = $userResponse.methodResponse.params.param.value.struct
$status = (Select-Xml -Xml $userStruct -XPath "//member[name/text()[normalize-space()='status']]/value").Node.'#text'
$userName = (Select-Xml -Xml $userStruct -XPath "//member[name/text()[normalize-space()='user']]/value/struct/member[name/text()[normalize-space()='userName']]/value").Node.'#text'
Write-Host "✅ User authentication complete." -ForegroundColor Green
Write-Host "   Status: $status"
Write-Host "   Username: $userName"
if ($status -ne "SUCCESS") {
    Write-Host "Authentication failed (Status: $status). Stopping script." -ForegroundColor Yellow
    return
}

# --- START OF THE NEW LOOP ---
Write-Host ""
Write-Host "--- Starting Release Loop for '$userName' ---" -ForegroundColor Cyan

while ($true) {
    
    # --- Step 3: Get and Filter Held Jobs ---
    Write-Host ""
    Write-Host "--- Step 3: Fetching and filtering held jobs for '$userName'..."
    $xmlIsManager = $(if ($isReleaseStationManager) { "<boolean>1</boolean>" } else { "<boolean>0</boolean>" })
    $xmlIncludeDenied = $(if ($includeDeniedJobs) { "<boolean>1</boolean>" } else { "<boolean>0</boolean>" })
    $getJobsPayload = @"
<?xml version="1.0"?>
<methodCall>
  <methodName>releaseStation.getHeldJobs2</methodName>
  <params>
    <param><value><string>$($authToken)</string></value></param>
    <param><value><string>$($releaseStationID)</string></value></param>
    <param><value>$($xmlIsManager)</value></param>
    <param><value><string>$($userName)</string></value></param>
    <param><value><array><data></data></array></value></param>
    <param><value>$($xmlIncludeDenied)</value></param>
    <param><value><string>$($locale)</string></value></param>
  </params>
</methodCall>
"@
    $jobsResponse = Invoke-PaperCutApi -xmlPayload $getJobsPayload
    if (-not $jobsResponse) { Write-Host "Stopping script."; return }

    $jobStructs = Select-Xml -Xml $jobsResponse -XPath "//methodResponse/params/param/value/array/data/value/struct"
    $heldJobIds = [System.Collections.ArrayList]::new()

    foreach ($jobStruct in $jobStructs) {
        $actionNode = Select-Xml -Node $jobStruct.Node -XPath "./member[name/text()[normalize-space()='action']]/value"
        $action = $actionNode.Node.'#text'

        if ($action -eq 'HOLD') {
            $eventIdNode = Select-Xml -Node $jobStruct.Node -XPath "./member[name/text()[normalize-space()='eventId']]/value"
            $eventId = $eventIdNode.Node.'#text'
            [void]$heldJobIds.Add($eventId)
        }
    }

    # --- THIS IS THE LOOP EXIT CONDITION ---
    if ($heldJobIds.Count -eq 0) {
        Write-Host "✅ Success. User '$userName' has 0 jobs left in the 'HOLD' state." -ForegroundColor Green
        Write-Host "--- Release Loop Finished ---" -ForegroundColor Cyan
        break # Exit the while($true) loop
    }
    Write-Host "✅ Success. Found $($heldJobIds.Count) jobs in the 'HOLD' state."


    # --- Step 4: Select and Release a Random Subset ---
    Write-Host ""
    Write-Host "--- Step 4: Selecting and Releasing Jobs ---"

    $totalHeldJobs = $heldJobIds.Count
    $actualReleaseCap = [Math]::Min($totalHeldJobs, $releaseCap)
    $jobsToReleaseCount = Get-Random -Minimum 1 -Maximum ($actualReleaseCap + 1)

    Write-Host "Smart Cap: Capping release at $actualReleaseCap jobs (whichever is lower: $totalHeldJobs held or $releaseCap max)."
    Write-Host "DECISION: Releasing a random number of $jobsToReleaseCount jobs."

    $jobsToRelease = $heldJobIds | Get-Random -Count $jobsToReleaseCount
    if ($jobsToRelease -is [String]) {
        $jobsToRelease = @($jobsToRelease) # Wrap a single item in an array
    }

    $jobArrayXml = ""
    foreach ($jobId in $jobsToRelease) {
        $jobArrayXml += "<value><string>$($jobId)</string></value>"
    }

    $releasePayload = @"
<?xml version="1.0"?>
<methodCall>
  <methodName>releaseStation.releaseJobs</methodName>
  <params>
    <param><value><string>$($authToken)</string></value></param>
    <param><value><string>$($releaseStationID)</string></value></param>
    <param>
      <value>
        <array>
          <data>
            $($jobArrayXml)
          </data>
        </array>
      </value>
    </param>
    <param><value><string></string></value></param>
    <param><value><array><data></data></array></value></param>
    <param><value><boolean>0</boolean></value></param>
  </params>
</methodCall>
"@

    Write-Host "Sending release command for jobs: $($jobsToRelease -join ', ')"
    try {
        $releaseResponse = Invoke-PaperCutApi -xmlPayload $releasePayload
        Write-Host "✅ Release command sent successfully." -ForegroundColor Green
    }
    catch {
        Write-Host "❌ FATAL ERROR: Failed to send release request." -ForegroundColor Red
        Write-Host $_.Exception.Message
    }
    
    Write-Host "--- Pausing for 5 seconds before next loop... ---"
    Start-Sleep -Seconds 0

} # --- END OF THE NEW LOOP ---
