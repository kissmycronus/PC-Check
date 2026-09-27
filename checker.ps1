foreach ($line in $headerLines) {
    Write-Host $line -ForegroundColor DarkRed
    Start-Sleep -Milliseconds 200
}
Start-Sleep -Seconds 2

Write-Host ""
Write-Host ""

$name = $env:USERNAME
$desktopPath = [System.Environment]::GetFolderPath('Desktop')
$tempFolder = Join-Path -Path $desktopPath -ChildPath "PCCheck_Temp"
$zipFileName = "$name`_PCCheck.zip"
$zipFilePath = Join-Path -Path $desktopPath -ChildPath $zipFileName

# Create temp folder for individual files
if (Test-Path $tempFolder) {
    Remove-Item -Path $tempFolder -Recurse -Force
}
New-Item -Path $tempFolder -ItemType Directory -Force | Out-Null

Clear-Host

Write-Host "Hello, $name! The script is now starting..." -ForegroundColor Green

# USB Device Configuration
$VendorID = "046D"  # Logitech VID
$DeviceID = "C53B"  # Specific PID for XIM Matrix

function Get-USBDevices {
    Write-Host "Scanning USB devices..." -ForegroundColor Blue
    $outputFile = Join-Path -Path $tempFolder -ChildPath "USBs.txt"
    Add-Content -Path $outputFile -Value "USB DEVICES:`n"
    
    try {
        $AllUSBDevices = Get-PnpDevice | Where-Object { 
            $_.Class -in @("HIDClass", "USB", "Mouse", "Keyboard") -and $_.Status -eq "OK" 
        }

        # Deduplicate by VID + PID
        $Seen = @{}
        $UniqueDevices = @()
        foreach ($Device in $AllUSBDevices) {
            $InstanceID = $Device.InstanceId
            if ($InstanceID -match 'VID_([0-9A-F]{4}).*PID_([0-9A-F]{4})') {
                $DeviceVID = $Matches[1]
                $DevicePID = $Matches[2]
                $key = "$DeviceVID`_$DevicePID"
                if (-not $Seen.ContainsKey($key)) {
                    $Seen[$key] = $true
                    $UniqueDevices += $Device
                }
            }
        }

        Add-Content -Path $outputFile -Value "Found $($UniqueDevices.Count) unique USB/HID device(s):`n"
        $DeviceCount = 0
        foreach ($Device in $UniqueDevices) {
            $DeviceCount++
            $InstanceID = $Device.InstanceId
            $DeviceVID = if ($InstanceID -match 'VID_([0-9A-F]{4})') { $Matches[1] } else { "Unknown" }
            $DevicePID = if ($InstanceID -match 'PID_([0-9A-F]{4})') { $Matches[1] } else { "Unknown" }
            Add-Content -Path $outputFile -Value "  [$DeviceCount] $($Device.FriendlyName) - VID_$DeviceVID & PID_$DevicePID"
        }
    } catch {
        Add-Content -Path $outputFile -Value "ERROR: Could not enumerate USB devices - $($_.Exception.Message)"
    }
}

function Check-XimMatrix {
    $ximTraces = @{
        LiveDevice = $false
        RegistryEntries = @()
        PrefetchFiles = @()
        BAMEntries = @()
    }
    
    # Check for live device with exact VID/PID match
    try {
        $AllDevices = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "OK" }
        foreach ($Device in $AllDevices) {
            $InstanceID = $Device.InstanceId
            if ($InstanceID -match "VID_$VendorID.*PID_$DeviceID") {
                $ximTraces.LiveDevice = $true
            }
        }
    } catch {}
    
    # Check USB Registry with exact VID/PID match
    try {
        $USBEnumPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\USB"
        if (Test-Path $USBEnumPath) {
            $USBKeys = Get-ChildItem -Path $USBEnumPath -ErrorAction SilentlyContinue
            foreach ($Key in $USBKeys) {
                if ($Key.PSChildName -match "VID_$VendorID.*PID_$DeviceID") {
                    $ximTraces.RegistryEntries += $Key.PSPath
                }
            }
        }
    } catch {}
    
    # Check Prefetch files
    try {
        $prefetchPath = "$env:SystemRoot\Prefetch"
        if (Test-Path $prefetchPath) {
            $prefetchFiles = Get-ChildItem -Path $prefetchPath -Filter "*.pf" -ErrorAction SilentlyContinue
            foreach ($file in $prefetchFiles) {
                if ($file.Name -match "XIM|046D.*C53B") {
                    $ximTraces.PrefetchFiles += $file.FullName
                }
            }
        }
    } catch {}
    
    # Check BAM/DAM registry
    try {
        $bamPath = "HKLM:\SYSTEM\CurrentControlSet\Services\bam\State\UserSettings"
        if (Test-Path $bamPath) {
            $userSettings = Get-ChildItem -Path $bamPath -ErrorAction SilentlyContinue
            foreach ($setting in $userSettings) {
                $items = Get-ItemProperty -Path $setting.PSPath -ErrorAction SilentlyContinue
                foreach ($prop in $items.PSObject.Properties) {
                    if ($prop.Name -match "XIM|Logitech.*C53B") {
                        $ximTraces.BAMEntries += $prop.Name
                    }
                }
            }
        }
    } catch {}
    
    return $ximTraces
}

function Scan-USBDevices {
    Write-Host "Starting USB device scan..." -ForegroundColor Yellow
    $outputFile = Join-Path -Path $tempFolder -ChildPath "USBs.txt"
    
    Get-USBDevices
    
    # Check for XIM Matrix traces
    $ximTraces = Check-XimMatrix
    $ximFound = $ximTraces.LiveDevice -or 
                $ximTraces.RegistryEntries.Count -gt 0 -or 
                $ximTraces.PrefetchFiles.Count -gt 0 -or 
                $ximTraces.BAMEntries.Count -gt 0
    
    Add-Content -Path $outputFile -Value "`n-----------------"
    Add-Content -Path $outputFile -Value "XIM MATRIX DETECTION:`n"
    
    if ($ximFound) {
        Add-Content -Path $outputFile -Value "[XIM Matrix Traces Found]`n"
        
        if ($ximTraces.LiveDevice) {
            Add-Content -Path $outputFile -Value "- Live Device: DETECTED (VID_046D & PID_C53B)"
        }
        
        if ($ximTraces.RegistryEntries.Count -gt 0) {
            Add-Content -Path $outputFile -Value "`n- Registry Entries:"
            foreach ($entry in $ximTraces.RegistryEntries) {
                Add-Content -Path $outputFile -Value "  $entry"
            }
        }
        
        if ($ximTraces.PrefetchFiles.Count -gt 0) {
            Add-Content -Path $outputFile -Value "`n- Prefetch Files:"
            foreach ($file in $ximTraces.PrefetchFiles) {
                Add-Content -Path $outputFile -Value "  $file"
            }
        }
        
        if ($ximTraces.BAMEntries.Count -gt 0) {
            Add-Content -Path $outputFile -Value "`n- BAM/DAM Entries:"
            foreach ($entry in $ximTraces.BAMEntries) {
                Add-Content -Path $outputFile -Value "  $entry"
            }
        }
    } else {
        Add-Content -Path $outputFile -Value "[No XIM Matrix traces found]"
    }
}

function Get-OneDrivePath {
    $oneDrivePath = (Get-ItemProperty "HKCU:\Software\Microsoft\OneDrive" -Name "UserFolder" -ErrorAction SilentlyContinue).UserFolder
    if (-not $oneDrivePath) {
        Write-Warning "OneDrive path not found in registry. Attempting alternative detection..."
        $envOneDrive = [System.IO.Path]::Combine($env:UserProfile, "OneDrive")
        if (Test-Path $envOneDrive) {
            $oneDrivePath = $envOneDrive
            Write-Host "OneDrive path detected using environment variable: $oneDrivePath" -ForegroundColor Green
        } else {
            Write-Error "Unable to find OneDrive path automatically."
            return $null
        }
    }
    return $oneDrivePath
}

function Format-Output {
    param($name, $value)
    "{0} : {1}" -f $name, $value -replace 'System.Byte\[\]', ''
}

function Find-RarAndExeFiles {
    Write-Output "Finding .rar and .exe files..."
    $outputFile = Join-Path -Path $tempFolder -ChildPath "Registry Executables.txt"
    $oneDriveFileHeader = "OneDrive Files:`n"
    $oneDriveFiles = [System.Collections.Generic.List[string]]::new()
    $allFiles = [System.Collections.Generic.List[string]]::new()
    $rarSearchPaths = Get-PSDrive -PSProvider 'FileSystem' | ForEach-Object { $_.Root }
    $oneDrivePath = Get-OneDrivePath
    if ($oneDrivePath) { $rarSearchPaths += $oneDrivePath }
    
    $searchFiles = {
        param ($path, $filter, $oneDriveFiles, $allFiles)
        Get-ChildItem -Path $path -Recurse -Filter $filter -ErrorAction SilentlyContinue | ForEach-Object {
            $allFiles.Add($_.FullName)
            if ($_.FullName -like "*OneDrive*") { $oneDriveFiles.Add($_.FullName) }
        }
    }
    
    try {
        $rarJob = Start-Job -ScriptBlock $searchFiles -ArgumentList $rarSearchPaths, "*.rar", $oneDriveFiles, $allFiles
        $exeJob = $null
        if ($oneDrivePath) {
            $exeJob = Start-Job -ScriptBlock $searchFiles -ArgumentList @($oneDrivePath), "*.exe", $oneDriveFiles, $allFiles
        }
        
        $rarJob | Wait-Job -ErrorAction SilentlyContinue
        if ($exeJob) { $exeJob | Wait-Job -ErrorAction SilentlyContinue }
        
        $rarResults = Receive-Job -Job $rarJob -ErrorAction SilentlyContinue
        $exeResults = if ($exeJob) { Receive-Job -Job $exeJob -ErrorAction SilentlyContinue } else { @() }
        
        if ($oneDriveFiles.Count -gt 0) {
            Add-Content -Path $outputFile -Value $oneDriveFileHeader
            $oneDriveFiles | Sort-Object | ForEach-Object { Add-Content -Path $outputFile -Value $_ }
            Add-Content -Path $outputFile -Value "`n"
        }
        
        ($rarResults + $exeResults) | Sort-Object -Unique | ForEach-Object { 
            if ($_) { Add-Content -Path $outputFile -Value $_ }
        }
    }
    finally {
        if ($rarJob) { Remove-Job -Job $rarJob -Force -ErrorAction SilentlyContinue }
        if ($exeJob) { Remove-Job -Job $exeJob -Force -ErrorAction SilentlyContinue }
    }
}

function Find-SusFiles {
    Write-Output "Searching for suspiciously named files..."
    $outputFile = Join-Path -Path $tempFolder -ChildPath "Suspicious Files.txt"
    $susFiles = @()

    # Regex for 10-char alphanumeric executable names (case-sensitive)
    $pattern = '^[A-Za-z0-9]{10}\.exe$'

    # Directories to search
    $searchPaths = @("C:\Users", "C:\Program Files", "C:\Program Files (x86)", "C:\Windows\Temp", "C:\Temp")

    foreach ($path in $searchPaths) {
        if (Test-Path $path) {
            try {
                $files = Get-ChildItem -Path $path -Recurse -File -ErrorAction SilentlyContinue

                foreach ($file in $files) {
                    if ($file.Name -match $pattern -or $file.Name -ieq "Dapper.dll") {
                        $susFiles += $file.FullName
                    }
                }
            } catch {
                Write-Output ("Error searching path '{0}': {1}" -f $path, $_.Exception.Message)
            }
        }
    }

    if ($susFiles.Count -gt 0) {
        Add-Content -Path $outputFile -Value "SUSPICIOUS FILES:`n"
        $susFiles | Sort-Object | ForEach-Object { Add-Content -Path $outputFile -Value $_ }
        Write-Output "Suspicious files logged."
    } else {
        Add-Content -Path $outputFile -Value "No suspicious files found."
        Write-Output "No suspicious files found."
    }
}

function Log-BrowserFolders {
    Write-Host "Logging browser folders..." -ForegroundColor DarkYellow
    $registryPath = "HKLM:\SOFTWARE\Clients\StartMenuInternet"
    $outputFile = Join-Path -Path $tempFolder -ChildPath "Browsers.txt"
    
    if (Test-Path $registryPath) {
        $browserFolders = Get-ChildItem -Path $registryPath
        Add-Content -Path $outputFile -Value "BROWSER FOLDERS:`n"
        foreach ($folder in $browserFolders) { 
            Add-Content -Path $outputFile -Value $folder.Name 
        }
    } else {
        Write-Host "Registry path for browsers not found." -ForegroundColor Red
        Add-Content -Path $outputFile -Value "Registry path for browsers not found."
    }
}

function Format-Output {
    param($name, $value)
    "{0} : {1}" -f $name, $value -replace 'System.Byte\[\]', ''
}

function List-BAMStateUserSettings {
    Write-Host "Logging reg entries inside PowerShell..." -ForegroundColor DarkYellow
    $outputFile = Join-Path -Path $tempFolder -ChildPath "Registry Executables.txt"
    $loggedPaths = @{}
    
    Write-Host " Fetching UserSettings Entries " -ForegroundColor Blue

    $registryPath = "HKLM:\SYSTEM\CurrentControlSet\Services\bam\State\UserSettings"
    $userSettings = Get-ChildItem -Path $registryPath | Where-Object { $_.Name -like "*1001" }

    Add-Content -Path $outputFile -Value "REGISTRY EXECUTABLES:`n"

    if ($userSettings) {
        foreach ($setting in $userSettings) {
            Add-Content -Path $outputFile -Value "`n$($setting.PSPath)"
            $items = Get-ItemProperty -Path $setting.PSPath | Select-Object -Property *
            foreach ($item in $items.PSObject.Properties) {
                if (($item.Name -match "exe" -or $item.Name -match ".rar") -and -not $loggedPaths.ContainsKey($item.Name)) {
                    Add-Content -Path $outputFile -Value (Format-Output $item.Name $item.Value)
                    $loggedPaths[$item.Name] = $true
                }
            }
        }
    } else {
        Write-Host "No relevant user settings found." -ForegroundColor Red
    }
    
    Write-Host "Fetching Compatibility Assistant Entries"

    $compatRegistryPath = "HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Compatibility Assistant\Store"
    $compatEntries = Get-ItemProperty -Path $compatRegistryPath
    $compatEntries.PSObject.Properties | ForEach-Object {
        if (($_.Name -match "exe" -or $_.Name -match ".rar") -and -not $loggedPaths.ContainsKey($_.Name)) {
            Add-Content -Path $outputFile -Value (Format-Output $_.Name $_.Value)
            $loggedPaths[$_.Name] = $true
        }
    }
    
    Write-Host "Fetching AppsSwitched Entries" -ForegroundColor Blue
    $newRegistryPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FeatureUsage\AppSwitched"
    if (Test-Path $newRegistryPath) {
        $newEntries = Get-ItemProperty -Path $newRegistryPath
        $newEntries.PSObject.Properties | ForEach-Object {
            if (($_.Name -match "exe" -or $_.Name -match ".rar") -and -not $loggedPaths.ContainsKey($_.Name)) {
                Add-Content -Path $outputFile -Value (Format-Output $_.Name $_.Value)
                $loggedPaths[$_.Name] = $true
            }
        }
    }
    
    Write-Host "Fetching MuiCache Entries" -ForegroundColor Blue
    $muiCachePath = "HKCR:\Local Settings\Software\Microsoft\Windows\Shell\MuiCache"
    if (Test-Path $muiCachePath) {
        $muiCacheEntries = Get-ChildItem -Path $muiCachePath
        $muiCacheEntries.PSObject.Properties | ForEach-Object {
            if (($_.Name -match "exe" -or $_.Name -match ".rar") -and -not $loggedPaths.ContainsKey($_.Name)) {
                Add-Content -Path $outputFile -Value (Format-Output $_.Name $_.Value)
                $loggedPaths[$_.Name] = $true
            }
        }
    }

    Get-Content $outputFile | Sort-Object | Get-Unique | Where-Object { $_ -notmatch "\{.*\}" } | ForEach-Object { $_ -replace ":", "" } | Set-Content $outputFile
}

function Log-SystemInfo {
    Write-Host "Logging system information..." -ForegroundColor DarkYellow
    $outputFile = Join-Path -Path $tempFolder -ChildPath "System Information.txt"
    
    Add-Content -Path $outputFile -Value "SYSTEM INFORMATION:`n"
    
    # Windows Install Date
    try {
        $os = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction Stop
        $installDate = $os.ConvertToDateTime($os.InstallDate)
        Add-Content -Path $outputFile -Value "Windows Installation Date: $installDate`n"
    } catch {
        Add-Content -Path $outputFile -Value "Windows Installation Date: Unknown (retrieval failed)`n"
    }
    
    # Windows Security Status
    Add-Content -Path $outputFile -Value "-----------------"
    Add-Content -Path $outputFile -Value "WINDOWS SECURITY STATUS:`n"
    
    try {
        $antivirusProducts = Get-WmiObject -Namespace "root\SecurityCenter2" -Class AntiVirusProduct -ErrorAction SilentlyContinue | 
                            Where-Object { $_.displayName -ne "Windows Defender" -and $_.displayName -ne $null }

        if ($antivirusProducts) {
            Add-Content -Path $outputFile -Value "Third-Party Antivirus Software Detected:"
            foreach ($product in $antivirusProducts) {
                $state = switch ($product.productState) {
                    "262144" { "Enabled" }
                    "262160" { "Disabled" }
                    "266240" { "Enabled" }
                    "266256" { "Disabled" }
                    "393216" { "Enabled" }
                    "393232" { "Disabled" }
                    "397312" { "Enabled" }
                    "397328" { "Disabled" }
                    default { "Unknown ($($product.productState))" }
                }
                Add-Content -Path $outputFile -Value ("Name: {0}, State: {1}" -f $product.displayName, $state)
            }
        } else {
            try {
                $securityStatus = Get-MpComputerStatus -ErrorAction Stop
                Add-Content -Path $outputFile -Value ("Antivirus Enabled: {0}" -f (if ($securityStatus.AntivirusEnabled) { "Enabled" } else { "Disabled" }))
                Add-Content -Path $outputFile -Value ("Real-Time Protection Enabled: {0}" -f (if ($securityStatus.RealTimeProtectionEnabled) { "Enabled" } else { "Disabled" }))
                Add-Content -Path $outputFile -Value ("Firewall Enabled: {0}" -f (if ($securityStatus.FirewallEnabled) { "Enabled" } else { "Disabled" }))
                Add-Content -Path $outputFile -Value ("Antispyware Enabled: {0}" -f (if ($securityStatus.AntispywareEnabled) { "Enabled" } else { "Disabled" }))
                Add-Content -Path $outputFile -Value ("AMService Enabled: {0}" -f (if ($securityStatus.AMServiceEnabled) { "Enabled" } else { "Disabled" }))
                Add-Content -Path $outputFile -Value ("Quick Scan Age (Days): {0}" -f $securityStatus.QuickScanAge)
                Add-Content -Path $outputFile -Value ("Full Scan Age (Days): {0}" -f $securityStatus.FullScanAge)
            } catch {
                Add-Content -Path $outputFile -Value "Failed to retrieve Windows Defender status."
            }
        }
    } catch {
        Add-Content -Path $outputFile -Value "Error retrieving security center information."
    }
    
    # Protection History
    Add-Content -Path $outputFile -Value "`n-----------------"
    Add-Content -Path $outputFile -Value "PROTECTION HISTORY:`n"
    
    try {
        $threats = Get-MpThreat -ErrorAction SilentlyContinue
        if ($threats) {
            foreach ($threat in $threats) {
                Add-Content -Path $outputFile -Value "Threat Detected:"
                Add-Content -Path $outputFile -Value ("Name: {0}" -f $threat.ThreatName)
                Add-Content -Path $outputFile -Value ("Severity: {0}" -f $threat.SeverityID)
                Add-Content -Path $outputFile -Value ("Action Taken: {0}" -f $threat.ActionSuccess)
                Add-Content -Path $outputFile -Value ("Detection Source: {0}" -f $threat.AMSIProviderName)
                Add-Content -Path $outputFile -Value ("Execution Path: {0}" -f $threat.ExecutionPath)
                Add-Content -Path $outputFile -Value ("Initial Detection Time: {0}" -f $threat.InitialDetectionTime)
                Add-Content -Path $outputFile -Value ("Remediation Time: {0}" -f $threat.RemediationTime)
                Add-Content -Path $outputFile -Value ""
            }
        } else {
            Add-Content -Path $outputFile -Value "No recent threats found in Protection History."
        }
    } catch {
        Add-Content -Path $outputFile -Value "Error: Unable to retrieve Protection History."
    }
    
    # System Info (Secure Boot & Kernel DMA)
    Add-Content -Path $outputFile -Value "-----------------"
    Add-Content -Path $outputFile -Value "SYSTEM INFO:`n"
    
    try {
        if ((Get-Command -Name Confirm-SecureBootUEFI -ErrorAction SilentlyContinue)) {
            $secureBoot = Confirm-SecureBootUEFI -ErrorAction SilentlyContinue
            $secureBootStatus = if ($secureBoot -eq $true) { "Enabled" } else { "Disabled" }
            Add-Content -Path $outputFile -Value ("Secure Boot: {0}" -f $secureBootStatus)
        } else {
            Add-Content -Path $outputFile -Value "Secure Boot: Not available on this system"
        }
    } catch {
        Add-Content -Path $outputFile -Value "Secure Boot: Unknown (retrieval failed)"
    }
    
    try {
        $dmaProtectionStatus = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard" -Name "EnableDmaProtection" -ErrorAction SilentlyContinue
        if ($dmaProtectionStatus -and $dmaProtectionStatus.EnableDmaProtection -eq 1) {
            Add-Content -Path $outputFile -Value "Kernel DMA Protection: Enabled"
        } else {
            Add-Content -Path $outputFile -Value "Kernel DMA Protection: Disabled or not supported"
        }
    } catch {
        Add-Content -Path $outputFile -Value "Kernel DMA Protection: Unknown (retrieval failed)"
    }
    
    # Registry Keys under AllowedBuses
    Add-Content -Path $outputFile -Value "`n-----------------"
    Add-Content -Path $outputFile -Value "REGISTRY KEYS UNDER ALLOWEDBUSES:`n"
    
    $registryPath = "HKLM:\SYSTEM\CurrentControlSet\Control\DmaSecurity\AllowedBuses"
    if (Test-Path -Path $registryPath) {
        try {
            $subkeys = Get-ChildItem -Path $registryPath -ErrorAction Stop
            if ($subkeys.Count -eq 0) {
                Add-Content -Path $outputFile -Value "No subkeys found (only default key exists)."
            } else {
                $subkeys | ForEach-Object {
                    Add-Content -Path $outputFile -Value $_.PSChildName
                }
            }
        } catch {
            Add-Content -Path $outputFile -Value "Error accessing registry path."
        }
    } else {
        Add-Content -Path $outputFile -Value "Registry path not found."
    }
}

function Search-PrefetchFiles {
    Write-Host "Searching prefetch files..." -ForegroundColor DarkYellow
    $prefetchFolderPath = "$env:SystemRoot\Prefetch"
    $outputFile = Join-Path -Path $tempFolder -ChildPath "Prefetch.txt"
    
    Add-Content -Path $outputFile -Value "PREFETCH FILES:`n"
    
    if (Test-Path $prefetchFolderPath) {
        try {
            $prefetchFiles = Get-ChildItem -Path $prefetchFolderPath -Filter "*.pf" -ErrorAction Stop | ForEach-Object {
                "{0} - Last Accessed: {1}" -f $_.Name, $_.LastAccessTime
            }
            
            if ($prefetchFiles.Count -gt 0) {
                $prefetchFiles | ForEach-Object { Add-Content -Path $outputFile -Value $_ }
            } else {
                Add-Content -Path $outputFile -Value "No prefetch files found."
            }
        } catch {
            Add-Content -Path $outputFile -Value "Error accessing prefetch folder."
        }
    } else {
        Add-Content -Path $outputFile -Value "Prefetch folder not found."
    }
}

function Log-LogitechScripts {
    Write-Host "Logging Logitech scripts..." -ForegroundColor DarkYellow
    $outputFile = Join-Path -Path $tempFolder -ChildPath "Logitech.txt"
    $scriptsPath = Join-Path -Path $env:LocalAppData -ChildPath "LGHUB\scripts"
    
    $scriptsFound = $false
    
    if (Test-Path -Path $scriptsPath) {
        try {
            $scriptFiles = Get-ChildItem -Path $scriptsPath -Recurse -File -ErrorAction Stop

            if ($scriptFiles -and $scriptFiles.Count -gt 0) {
                $scriptsFound = $true
                Add-Content -Path $outputFile -Value "LOGITECH SCRIPTS:`n"
                foreach ($file in $scriptFiles) {
                    Add-Content -Path $outputFile -Value ("{0} - Last Modified: {1}" -f $file.FullName, $file.LastWriteTime)
                }
            }
        } catch {}
    }
    
    if (-not $scriptsFound) {
        # Remove the file if no scripts were found
        if (Test-Path $outputFile) {
            Remove-Item -Path $outputFile -Force
        }
        Write-Host "No Logitech scripts found" -ForegroundColor Yellow
    } else {
        Write-Host "Logitech scripts logged." -ForegroundColor Green
    }
}

function Log-MonitorsEDID {
    Write-Host "Logging connected monitor information..." -ForegroundColor DarkYellow
    $outputFile = Join-Path -Path $tempFolder -ChildPath "Monitors.txt"
    
    Add-Content -Path $outputFile -Value "MONITORS AND EDID INFORMATION:`n"

    try {
        $monitors = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID

        if ($monitors) {
            foreach ($monitor in $monitors) {
                $name = ($monitor.UserFriendlyName | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ }) -join ""
                $serial = ($monitor.SerialNumberID | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ }) -join ""
                Add-Content -Path $outputFile -Value ("Monitor Name: {0}, Serial/EDID: {1}" -f $name, $serial)
            }
        } else {
            Add-Content -Path $outputFile -Value "No monitor EDID info found."
        }
    } catch {
        Add-Content -Path $outputFile -Value "Error retrieving monitor EDID information."
    }
}

function Log-PCIeDevices {
    Write-Host "Logging PCIe devices..." -ForegroundColor DarkYellow
    $outputFile = Join-Path -Path $tempFolder -ChildPath "PCIE Devices.txt"
    
    Add-Content -Path $outputFile -Value "PCIE DEVICES:`n"

    try {
        $pcieDevices = Get-PnpDevice | Where-Object { $_.InstanceId -like "PCI*" }

        if ($pcieDevices) {
            foreach ($device in $pcieDevices) {
                Add-Content -Path $outputFile -Value ("Name: {0}, Instance ID: {1}, Status: {2}" -f $device.Name, $device.InstanceId, $device.Status)
            }
        } else {
            Add-Content -Path $outputFile -Value "No PCIe devices found."
        }
    } catch {
        Add-Content -Path $outputFile -Value "Error retrieving PCIe devices."
    }
}

function Log-R6AndSteamBanStatus {
    Write-Host "Logging Rainbow Six Siege and Steam account status..." -ForegroundColor DarkYellow
    $outputFile = Join-Path -Path $tempFolder -ChildPath "R6 & Steam Accounts.txt"
    
    Add-Content -Path $outputFile -Value "RAINBOW SIX SIEGE & STEAM ACCOUNT STATUS:`n"

    $userName = $env:UserName

    # R6 Paths
    $potentialPaths = @(
        "C:\Users\$userName\Documents\My Games\Rainbow Six - Siege",
        "C:\Users\$userName\AppData\Local\Ubisoft Game Launcher\spool",
        "C:\Program Files (x86)\Ubisoft\Ubisoft Game Launcher\savegames"
    )

    # OneDrive R6 support
    $oneDriveRegPaths = @(
        "HKCU:\Software\Microsoft\OneDrive\Accounts\Business1\UserFolder",
        "HKCU:\Software\Microsoft\OneDrive\Accounts\Personal\UserFolder",
        "HKCU:\Software\Microsoft\OneDrive\UserFolder"
    )
    foreach ($regPath in $oneDriveRegPaths) {
        try {
            $oneDrivePath = Get-ItemProperty -Path ($regPath | Split-Path) -Name ($regPath | Split-Path -Leaf) -ErrorAction SilentlyContinue
            if ($oneDrivePath) {
                $potentialPaths += "$($oneDrivePath.UserFolder)\Documents\My Games\Rainbow Six - Siege"
                break
            }
        } catch {}
    }

    # Add Ubisoft cache folders
    $ubisoftCachePaths = @("ownership", "club", "conversations", "game_stats", "ptdata", "settings") | ForEach-Object {
        "C:\Program Files (x86)\Ubisoft\Ubisoft Game Launcher\cache\$_"
    }
    $potentialPaths += $ubisoftCachePaths

    $allUserNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $potentialPaths) {
        if (Test-Path -Path $path) {
            if ($path -like "*\cache\*") {
                Get-ChildItem -Path $path -File | ForEach-Object {
                    [void]$allUserNames.Add($_.Name)
                }
            } else {
                Get-ChildItem -Path $path -Directory | ForEach-Object {
                    [void]$allUserNames.Add($_.Name)
                }
            }
        }
    }

    Add-Content -Path $outputFile -Value "Rainbow Six Siege Accounts:`n"
    
    foreach ($name in ($allUserNames | Sort-Object)) {
        try {
            $url = "https://stats.cc/siege/$name"
            Write-Host "Checking stats for $name on Stats.cc ..." -ForegroundColor Blue
            
            $response = Invoke-WebRequest -Uri $url -UseBasicParsing
            $content = $response.Content

            if ($content -match '<title>Siege Stats - Stats.CC (.*?) - Rainbow Six Siege Player Stats</title>') {
                $accountName = $matches[1]
                $status = "Active"
                $banType = "None"

                if ($content -match '<div id="Ubisoft Bans".*?<div>Cheating</div>') {
                    $status = "Banned"; $banType = "Cheating"
                } elseif ($content -match '<div id="Ubisoft Bans".*?<div>Toxic Behavior</div>') {
                    $status = "Banned"; $banType = "Toxic Behavior"
                } elseif ($content -match '<div id="Ubisoft Bans".*?<div>Botting</div>') {
                    $status = "Banned"; $banType = "Botting"
                } elseif ($content -match '<div id="Reputation Bans" class="text-sm">Reputation Bans</div>') {
                    $status = "Banned"; $banType = "Reputation"
                }

                $resultLine = "$accountName - Status: $status, Type: $banType"
                Add-Content -Path $outputFile -Value $resultLine
            }
        } catch {
            Add-Content -Path $outputFile -Value "$name - Status: Error checking stats"
        }
    }

    # STEAM BAN CHECK
    Add-Content -Path $outputFile -Value "`n-----------------"
    Add-Content -Path $outputFile -Value "Steam Account Status:`n"
    
    $avatarCachePath = "C:\Program Files (x86)\Steam\config\avatarcache"
    $steamIds = @()

    if (Test-Path $avatarCachePath) {
        $steamIds += Get-ChildItem -Path $avatarCachePath -Filter "*.png" |
                     ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) }
    }

    $loginUsersPath = "C:\Program Files (x86)\Steam\config\loginusers.vdf"
    if (Test-Path $loginUsersPath) {
        $content = Get-Content $loginUsersPath -Raw
        $matches = [regex]::Matches($content, '"(7656[0-9]{13})"[\s\n]*{[\s\n]*"AccountName"\s*"([^"]*)"')
        foreach ($match in $matches) {
            $steamId = $match.Groups[1].Value
            $accountName = $match.Groups[2].Value
            
            Write-Host "Checking Steam profile for $accountName ..." -ForegroundColor Cyan
            $steamUrl = "https://steamcommunity.com/profiles/$steamId"
            
            try {
                $response = Invoke-WebRequest -Uri $steamUrl -UseBasicParsing
                $banStatus = if ($response.Content -match 'profile_ban_info') { "VAC banned" } else { "No VAC bans" }
                $resultLine = "$accountName - ID: $steamId, Status: $banStatus"
                Add-Content -Path $outputFile -Value $resultLine
            } catch {
                Add-Content -Path $outputFile -Value "$accountName - ID: $steamId - Status: VAC Check Failed"
            }
        }
    }
}

# Main execution
$oneDrivePath = Get-OneDrivePath
if ($oneDrivePath) {
    Write-Host "OneDrive path: $oneDrivePath" -ForegroundColor Green
} else {
    Write-Host "OneDrive path could not be determined." -ForegroundColor Yellow
}

# Execute all functions
Find-SusFiles
List-BAMStateUserSettings
Find-RarAndExeFiles
Log-BrowserFolders
Log-SystemInfo
Search-PrefetchFiles
Log-MonitorsEDID
Log-PCIeDevices
Scan-USBDevices
Log-R6AndSteamBanStatus
Log-LogitechScripts

# Create ZIP file
Write-Host "`nCreating ZIP file..." -ForegroundColor Green
try {
    if (Test-Path $zipFilePath) {
        Remove-Item -Path $zipFilePath -Force
    }
    
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory($tempFolder, $zipFilePath)
    
    Write-Host "ZIP file created successfully: $zipFilePath" -ForegroundColor Green
} catch {
    Write-Host "Failed to create ZIP file: $($_.Exception.Message)" -ForegroundColor Red
}

# Clean up temp folder
Remove-Item -Path $tempFolder -Recurse -Force

# FILE DELETION FUNCTION
$userProfile = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
$downloadsPath = Join-Path -Path $userProfile -ChildPath "Downloads"

function Delete-FileIfExists {
    param (
        [string]$filePath
    )
    if (Test-Path -Path $filePath) {
        Remove-Item -Path $filePath -Force -ErrorAction SilentlyContinue
    }
}

$targetFileDesktop = Join-Path -Path $desktopPath -ChildPath "PcCheck.txt"
$targetFileDownloads = Join-Path -Path $downloadsPath -ChildPath "PcCheck.txt"

Delete-FileIfExists -filePath $targetFileDesktop
Delete-FileIfExists -filePath $targetFileDownloads

Write-Host "`nScript execution completed." -ForegroundColor Green
Write-Host "Results saved to: $zipFilePath" -ForegroundColor Cyan
