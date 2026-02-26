<#
.SYNOPSIS
    Tests sequential disk write speed to validate Storage Throughput.
    CRITICAL: Uses 'WriteThrough' to bypass Windows RAM caching and hit the physical disk.
    Update: Explicitly reports achieved speed in the final status line.
#>

# --- CONFIGURATION ---
# Set this to the drive/folder where PaperCut stores temp scans and logs
# e.g., "C:\Program Files\PaperCut MF\server\data\tmp" or "C:\Temp"
$targetPath = "C:\Temp\disk_speed_test.dat"

# Test File Size (Must be large enough to sustain a write)
# 1024 MB (1GB) is a good standard test size
$fileSizeMB = 1024 

# Buffer Size (64KB is standard for large file moves)
$bufferSize = 64 * 1024 

# --- EXECUTION ---

# Ensure directory exists
$dir = Split-Path $targetPath -Parent
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

$buffer = New-Object byte[] $bufferSize
# Fill buffer with random data (prevents smart compression from cheating)
(New-Object Random).NextBytes($buffer)

Write-Host "--- Starting Disk Write Test ---" -ForegroundColor Cyan
Write-Host "  Target:    $targetPath"
Write-Host "  Size:      $fileSizeMB MB"
Write-Host "  Cache:     DISABLED (WriteThrough enforced)"
Write-Host "  Please wait..."

$sw = [System.Diagnostics.Stopwatch]::StartNew()

try {
    # Calculate flags separately to avoid PowerShell parsing errors
    # WriteThrough: Forces data to be written to disk immediately (bypassing OS cache)
    # DeleteOnClose: Automatically deletes the file when we close the handle
    $fileFlags = [int][System.IO.FileOptions]::WriteThrough -bor [int][System.IO.FileOptions]::DeleteOnClose

    $fs = New-Object System.IO.FileStream(
        $targetPath, 
        [System.IO.FileMode]::Create, 
        [System.IO.FileAccess]::ReadWrite, 
        [System.IO.FileShare]::None, 
        $bufferSize, 
        [System.IO.FileOptions]$fileFlags
    )

    $bytesToWrite = $fileSizeMB * 1024 * 1024
    $bytesWritten = 0

    while ($bytesWritten -lt $bytesToWrite) {
        $fs.Write($buffer, 0, $buffer.Length)
        $bytesWritten += $buffer.Length
    }
    
    # Force flush just to be absolutely sure
    $fs.Flush($true)
    $sw.Stop()
    
    $seconds = $sw.Elapsed.TotalSeconds
    $speedMBps = $fileSizeMB / $seconds
    $speedStr = $speedMBps.ToString("N2")

    Write-Host ""
    Write-Host "--- Results ---" -ForegroundColor Green
    Write-Host "  Time:      $($seconds.ToString("N2")) seconds"
    Write-Host "  Raw Speed: $speedStr MB/s"
    
    # Interpretation for Azure P20 (Modified to show speed in verdict)
    Write-Host ""
    if ($speedMBps -ge 145) {
        Write-Host "✅ PASS: Achieved $speedStr MB/s. Meets or exceeds Azure P20 spec (~150 MB/s)." -ForegroundColor Green
    } elseif ($speedMBps -ge 100) {
        Write-Host "⚠️  WARNING: Achieved $speedStr MB/s. Functional but below P20 spec. Monitor during heavy scanning." -ForegroundColor Yellow
    } else {
        Write-Host "❌ FAIL: Achieved only $speedStr MB/s. Significantly slow (<100 MB/s). This WILL bottleneck scanning." -ForegroundColor Red
    }

}
catch {
    Write-Error "Test Failed: $_"
}
finally {
    if ($fs) { $fs.Dispose() }
}
