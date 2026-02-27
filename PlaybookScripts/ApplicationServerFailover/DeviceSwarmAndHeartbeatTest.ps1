<#
.SYNOPSIS
    "The Active Swarm" - Stateful Device & User Load Tester.
    1. Spawns X devices (Heap Load).
    2. Simulates Y user logins per minute across that fleet (Auth/CPU Load).
    3. Maintains heartbeats for all devices.
#>

# --- 1. CONFIGURATION ---

$serverHost = "" 
$serverPort = 9191
$httpProtocol = "http"
$xmlRpcUrl = "{0}://{1}:{2}/rpc/extdevice/xmlrpc" -f $httpProtocol, $serverHost, $serverPort

# Auth
$vendorId = "beta"
$authDetails = "8e7f71b5872306506c0d20886d45203b" 
$testUsername = "admin"
$testPassword = "130252"

# Swarm Size (Heap Load)
$targetDeviceCount = 200   
$rampUpDelayMs = 20        

# Activity Settings (CPU/Auth Load)
$loginsPerMinute = 30      # How many users log in across the fleet per minute
$loopIntervalSeconds = 5   # How often to process a batch of logins

# --- 2. HELPER FUNCTIONS ---

function Invoke-XmlRpc {
    param([string]$Url, [string]$MethodName, [string[]]$ParamsXml)
    $pString = $ParamsXml -join ""
    $xml = "<?xml version='1.0'?><methodCall><methodName>$MethodName</methodName><params>$pString</params></methodCall>"
    try {
        $response = Invoke-WebRequest -Uri $Url -Method Post -Body $xml -ContentType "text/xml" -ErrorAction Stop
        return [xml]$response.Content
    } catch { return $null }
}

function New-XmlString { param([string]$s) return "<param><value><string>$s</string></value></param>" }
function New-XmlInt { param([int]$i) return "<param><value><int>$i</int></value></param>" }

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

# --- 3. PHASE 1: RAMP UP (Spawn the Fleet) ---

Write-Host "--- Starting THE ACTIVE SWARM ---" -ForegroundColor Cyan
Write-Host "  Fleet Size:  $targetDeviceCount devices"
Write-Host "  Activity:    $loginsPerMinute logins/minute"
Write-Host "---------------------------------"

$activeBots = New-Object System.Collections.Generic.List[PSCustomObject]

for ($i = 1; $i -le $targetDeviceCount; $i++) {
    $botName = "SwarmBot-$i"
    if ($i % 50 -eq 0) { Write-Host "[$i/$targetDeviceCount] Spawning $botName..." }

    try {
        # Handshake & Register
        $resp = Invoke-XmlRpc -Url $xmlRpcUrl -MethodName "api.beginSession" -ParamsXml @((New-XmlString $vendorId), (New-XmlString $authDetails), (New-XmlInt 1))
        $sessionId = $resp.SelectSingleNode("//member[name='sessionId']/value").InnerText
        if (-not $sessionId) { $sessionId = $resp.SelectSingleNode("//methodResponse/params/param/value").InnerText }
        
        if ($sessionId) {
            $caps = "<param><value><struct><member><name>scan</name><value><array><data><value><string>TRUE</string></value></data></array></value></member></struct></value></param>"
            $resp = Invoke-XmlRpc -Url $xmlRpcUrl -MethodName "api.registerDeviceWithCapabilities" -ParamsXml @((New-XmlString $sessionId), (New-XmlString $botName), (New-XmlString "GENERIC"), $caps)
            $deviceId = $resp.SelectSingleNode("//member[name='deviceId']/value").InnerText

            # Initial Status: Online
            $statusXml = New-StatusStruct -description "Swarm Bot Online" -inUse $false
            Invoke-XmlRpc -Url $xmlRpcUrl -MethodName "api.updateDeviceStatus" -ParamsXml @((New-XmlString $sessionId), (New-XmlString $deviceId), $statusXml) | Out-Null

            [void]$activeBots.Add([PSCustomObject]@{
                Name = $botName
                SessionId = $sessionId
                DeviceId = $deviceId
                LastHeartbeat = [DateTime]::Now
            })
        }
    } catch {}
    Start-Sleep -Milliseconds $rampUpDelayMs
}

Write-Host "`n--- FLEET ONLINE: $($activeBots.Count) Devices ---" -ForegroundColor Yellow

# --- 4. PHASE 2: THE ACTIVITY LOOP ---

# Calculate items per loop
$loginsPerLoop = [Math]::Ceiling($loginsPerMinute * ($loopIntervalSeconds / 60))
Write-Host "Targeting $loginsPerLoop logins every $loopIntervalSeconds seconds."

while ($true) {
    $loopStart = [DateTime]::Now
    
    # 1. Pick Random Devices for Activity
    $busyBots = $activeBots | Get-Random -Count $loginsPerLoop
    
    foreach ($bot in $busyBots) {
        # Simulate Walk-up
        # A. Login
        Invoke-XmlRpc -Url $xmlRpcUrl -MethodName "api.authenticateUserWithPassword" -ParamsXml @((New-XmlString $bot.SessionId), (New-XmlString $bot.DeviceId), (New-XmlString $testUsername), (New-XmlString $testPassword), (New-XmlInt 0)) | Out-Null
        
        # B. Set Status: Busy
        $statusXml = New-StatusStruct -description "User '$testUsername' logged in" -inUse $true
        Invoke-XmlRpc -Url $xmlRpcUrl -MethodName "api.updateDeviceStatus" -ParamsXml @((New-XmlString $bot.SessionId), (New-XmlString $bot.DeviceId), $statusXml) | Out-Null
        
        # C. Logout / Reset
        $statusXml = New-StatusStruct -description "Awaiting user login" -inUse $false
        Invoke-XmlRpc -Url $xmlRpcUrl -MethodName "api.updateDeviceStatus" -ParamsXml @((New-XmlString $bot.SessionId), (New-XmlString $bot.DeviceId), $statusXml) | Out-Null
        
        # Mark as "Heartbeated" so we don't double up
        $bot.LastHeartbeat = [DateTime]::Now
    }

    # 2. Maintain Heartbeats for Idle Devices (Every 60s)
    $idleCount = 0
    foreach ($bot in $activeBots) {
        if (([DateTime]::Now - $bot.LastHeartbeat).TotalSeconds -gt 60) {
            $statusXml = New-StatusStruct -description "Swarm Bot Idle" -inUse $false
            Invoke-XmlRpc -Url $xmlRpcUrl -MethodName "api.updateDeviceStatus" -ParamsXml @((New-XmlString $bot.SessionId), (New-XmlString $bot.DeviceId), $statusXml) | Out-Null
            $bot.LastHeartbeat = [DateTime]::Now
            $idleCount++
        }
    }

    Write-Host "[$($loopStart.ToString("HH:mm:ss"))] Activity: $($busyBots.Count) Logins | Maintenance: $idleCount Heartbeats" -ForegroundColor Green

    # Pacing
    $elapsed = ([DateTime]::Now - $loopStart).TotalSeconds
    if ($elapsed -lt $loopIntervalSeconds) {
        Start-Sleep -Seconds ($loopIntervalSeconds - $elapsed)
    }
}
