foreach ($line in $headerLines) {
    Write-Host $line -ForegroundColor DarkRed
    Start-Sleep -Milliseconds 200
}
Start-Sleep -Seconds 2

Write-Host ""
Write-Host ""

$name = $env:USERNAME
$logFileName = "$name`_Log.txt"

Clear-Host

Write-Host "Hello, $name! The script is now starting..." -ForegroundColor Green

# USB Device Configuration
$VendorID = "046D"  # Logitech VID
$DeviceID = "C53B"  # Specific PID to check for

function Get-USBDevices {
    Write-Host "Scanning USB devices..." -ForegroundColor Blue
    $desktopPath = [System.Environment]::GetFolderPath('Desktop')
    $outputFile = Join-Path -Path $desktopPath -ChildPath $logFileName
    Add-Content -Path $outputFile -Value "`nUSB DEVICES:"
    
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

        Add-Content -Path $outputFile -Value "Found $($UniqueDevices.Count) unique USB/HID device(s):"
        $DeviceCount = 0
        foreach ($Device in $UniqueDevices) {
            $DeviceCount++
            $InstanceID = $Device.InstanceId
            $DeviceVID = if ($InstanceID -match 'VID_([0-9A-F]{4})') { $Matches[1] } else { "Unknown" }
            $DevicePID = if ($InstanceID -match 'PID_([0-9A-F]{4})') { $Matches[1] } else { "Unknown" }
            Add-Content -Path $outputFile -Value "  [$DeviceCount] $($Device.FriendlyName) - VEN_$DeviceVID & PID_$DevicePID"
        }
    } catch {
        Add-Content -Path $outputFile -Value "ERROR: Could not enumerate USB devices - $($_.Exception.Message)"
    }
}

function Check-XimMatrix {
    $XimLive = $false
    try {
        $AllDevices = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "OK" }
        foreach ($Device in $AllDevices) {
            $InstanceID = $Device.InstanceId
            if ($InstanceID -like "*VID_$VendorID*" -and $InstanceID -like "*PID_$DeviceID*") {
                $XimLive = $true
            }
        }
    } catch { 
        # Silently continue
    }
    return $XimLive
}

function Check-USBRegistry {
    $XimRegistry = $false
    try {
        $USBEnumPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\USB"
        if (Test-Path $USBEnumPath) {
            $USBKeys = Get-ChildItem -Path $USBEnumPath -ErrorAction SilentlyContinue
            foreach ($Key in $USBKeys) {
                if ($Key.PSChildName -match "VID_$VendorID.*PID_$DeviceID") {
                    $XimRegistry = $true
                }
            }
        }
    } catch { 
        # Silently continue
    }
    return $XimRegistry
}

function Scan-USBDevices {
    Write-Host "Starting USB device scan..." -ForegroundColor Yellow
    $desktopPath = [System.Environment]::GetFolderPath('Desktop')
    $outputFile = Join-Path -Path $desktopPath -ChildPath $logFileName
    
    Get-USBDevices
    
    # Check for XIM Matrix but don't log the results unless found
    $XimLive = Check-XimMatrix
    $XimRegistry = Check-USBRegistry
    $XimFound = $XimLive -or $XimRegistry
    
    # Only log if XIM is found
    if ($XimFound) {
        Add-Content -Path $outputFile -Value "`n[Xim Matrix Found]"
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
    $desktopPath = [System.Environment]::GetFolderPath('Desktop')
    $outputFile = Join-Path -Path $desktopPath -ChildPath $logFileName
    $oneDriveFileHeader = "`n-----------------`nOneDrive Files:`n"
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


function Log-BrowserFolders {
    Write-Host "Checking for installed browsers..." -ForegroundColor DarkYellow

    $desktopPath = [System.Environment]::GetFolderPath('Desktop')
    $outputFile  = Join-Path -Path $desktopPath -ChildPath $logFileName

    # Browsers we care about.
    # Each entry:
    #   Name        -> canonical display name written to the log
    #   Patterns    -> substrings matched against the registry DisplayName
    #   Exclude     -> substrings that must NOT appear in the registry DisplayName
    #   FolderHints -> relative paths under Program Files / Program Files (x86) / LocalAppData
    $targetBrowsers = @(
        @{ Name = "Google Chrome";      Patterns = @("Google Chrome");                  Exclude = @("WebView");  FolderHints = @("Google\Chrome\Application") },
        @{ Name = "Microsoft Edge";     Patterns = @("Microsoft Edge");                 Exclude = @("WebView");  FolderHints = @("Microsoft\Edge\Application") },
        @{ Name = "Mozilla Firefox";    Patterns = @("Mozilla Firefox", "Firefox");     Exclude = @();           FolderHints = @("Mozilla Firefox") },
        @{ Name = "Opera GX";           Patterns = @("Opera GX");                       Exclude = @();           FolderHints = @("Programs\Opera GX", "Opera GX") },
        @{ Name = "Brave";              Patterns = @("Brave");                          Exclude = @();           FolderHints = @("BraveSoftware\Brave-Browser\Application", "Brave") },
        @{ Name = "DuckDuckGo Browser"; Patterns = @("DuckDuckGo");                     Exclude = @();           FolderHints = @("DuckDuckGo", "Programs\DuckDuckGo") },
        @{ Name = "Helium";             Patterns = @("Helium");                         Exclude = @();           FolderHints = @("Helium", "Programs\Helium") },
        @{ Name = "Mullvad Browser";    Patterns = @("Mullvad Browser");                Exclude = @("VPN");      FolderHints = @("Mullvad Browser", "Programs\Mullvad Browser") }
    )

    # ------------------------------------------------------------------
    # 1) Gather installed applications from registry uninstall keys
    # ------------------------------------------------------------------
    $uninstallPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    $installedApps = @()
    foreach ($path in $uninstallPaths) {
        try {
            $installedApps += Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
                              Where-Object { $_.DisplayName } |
                              Select-Object DisplayName, DisplayVersion, InstallLocation, Publisher
        } catch {}
    }

    # ------------------------------------------------------------------
    # 2) Common install folders (fallback if registry is missing)
    # ------------------------------------------------------------------
    $installFolders = @(
        "$env:ProgramFiles",
        "${env:ProgramFiles(x86)}",
        "$env:LocalAppData"
    )

    # ------------------------------------------------------------------
    # 3) Determine which browsers are installed (name-only output)
    # ------------------------------------------------------------------
    $detectedBrowsers = @()
    foreach ($browser in $targetBrowsers) {
        $isInstalled = $false

        # Registry check
        foreach ($app in $installedApps) {
            $nameMatch = $false
            foreach ($pat in $browser.Patterns) {
                if ($app.DisplayName -like "*$pat*") { $nameMatch = $true; break }
            }
            if (-not $nameMatch) { continue }

            $excluded = $false
            foreach ($ex in $browser.Exclude) {
                if ($app.DisplayName -like "*$ex*") { $excluded = $true; break }
            }
            if ($excluded) { continue }

            $isInstalled = $true
            break
        }

        # Folder check (only if not already found)
        if (-not $isInstalled) {
            foreach ($root in $installFolders) {
                if (-not (Test-Path $root)) { continue }
                foreach ($hint in $browser.FolderHints) {
                    $candidate = Join-Path -Path $root -ChildPath $hint
                    if (Test-Path $candidate) {
                        $isInstalled = $true
                        break
                    }
                }
                if ($isInstalled) { break }
            }
        }

        if ($isInstalled) {
            $detectedBrowsers += $browser.Name
        }
    }

    # Only write the section if at least one browser was found
    if ($detectedBrowsers.Count -gt 0) {
        Add-Content -Path $outputFile -Value "`n-----------------"
        Add-Content -Path $outputFile -Value "`nInstalled Browsers:"
        foreach ($b in $detectedBrowsers) {
            Add-Content -Path $outputFile -Value $b
        }
    }

    Write-Host "Installed browser info logged in $logFileName" -ForegroundColor Green
}

function List-BAMStateUserSettings {
    Write-Host "Logging reg entries inside PowerShell..." -ForegroundColor DarkYellow
    $desktopPath = [System.Environment]::GetFolderPath('Desktop')
    $outputFile = Join-Path -Path $desktopPath -ChildPath $logFileName
    if (Test-Path $outputFile) { Clear-Content $outputFile }
    $loggedPaths = @{}
     Write-Host " Fetching UserSettings Entries " -ForegroundColor Blue

    $registryPath = "HKLM:\SYSTEM\CurrentControlSet\Services\bam\State\UserSettings"
    $userSettings = Get-ChildItem -Path $registryPath | Where-Object { $_.Name -like "*1001" }

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
    Log-BrowserFolders
}
function Log-WindowsInstallDate {
    Write-Host "Logging Windows install date..." -ForegroundColor DarkYellow
    $desktopPath = [System.Environment]::GetFolderPath('Desktop')
    $outputFile = Join-Path -Path $desktopPath -ChildPath $logFileName
    
    try {
        $os = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction Stop
        $installDate = $os.ConvertToDateTime($os.InstallDate)
        Add-Content -Path $outputFile -Value "`n-----------------"
        Add-Content -Path $outputFile -Value "`nWindows Installation Date: $installDate"
    } catch {
        Write-Host "Failed to retrieve Windows installation date." -ForegroundColor Red
        Add-Content -Path $outputFile -Value "`n-----------------"
        Add-Content -Path $outputFile -Value "`nWindows Installation Date: Unknown (retrieval failed)"
    }
}

function Search-PrefetchFiles {
    $prefetchFolderPath = "$env:SystemRoot\Prefetch"
    $outputFile = Join-Path -Path ([System.Environment]::GetFolderPath('Desktop')) -ChildPath $logFileName
    $prefetchHeader = "`n-----------------`nPrefetch Files:`n"
    
    if (Test-Path $prefetchFolderPath) {
        try {
            $prefetchFiles = Get-ChildItem -Path $prefetchFolderPath -Filter "*.pf" -ErrorAction Stop | ForEach-Object {
                "{0} - Last Accessed: {1}" -f $_.Name, $_.LastAccessTime
            }
            
            if ($prefetchFiles.Count -gt 0) {
                Add-Content -Path $outputFile -Value $prefetchHeader
                $prefetchFiles | ForEach-Object { Add-Content -Path $outputFile -Value $_ }
                Write-Host "Prefetch file information saved to $outputFile" -ForegroundColor Green
            } else {
                Write-Host "No prefetch files found." -ForegroundColor Yellow
                Add-Content -Path $outputFile -Value $prefetchHeader
                Add-Content -Path $outputFile -Value "No prefetch files found."
            }
        } catch {
            Write-Host "Error accessing prefetch folder." -ForegroundColor Red
            Add-Content -Path $outputFile -Value $prefetchHeader
            Add-Content -Path $outputFile -Value "Error accessing prefetch folder."
        }
    } else {
        Write-Host "Prefetch folder not found." -ForegroundColor Red
        Add-Content -Path $outputFile -Value $prefetchHeader
        Add-Content -Path $outputFile -Value "Prefetch folder not found."
    }
}

function Log-WindowsSecurityStatus {
    Write-Host "Logging Windows Security status..." -ForegroundColor DarkYellow
    $desktopPath = [System.Environment]::GetFolderPath('Desktop')
    $outputFile = Join-Path -Path $desktopPath -ChildPath $logFileName
    $securityHeader = "`n-----------------`nWindows Security Status:`n"
    Add-Content -Path $outputFile -Value $securityHeader
    
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
            Write-Host "Third-party antivirus software in $logFileName" -ForegroundColor Green
        } else {
            Write-Host "No third-party antivirus software found. Logging Windows Defender status..." -ForegroundColor Yellow
            try {
                $securityStatus = Get-MpComputerStatus -ErrorAction Stop
                Add-Content -Path $outputFile -Value ("Antivirus Enabled: {0}" -f (if ($securityStatus.AntivirusEnabled) { "Enabled" } else { "Disabled" }))
                Add-Content -Path $outputFile -Value ("Real-Time Protection Enabled: {0}" -f (if ($securityStatus.RealTimeProtectionEnabled) { "Enabled" } else { "Disabled" }))
                Add-Content -Path $outputFile -Value ("Firewall Enabled: {0}" -f (if ($securityStatus.FirewallEnabled) { "Enabled" } else { "Disabled" }))
                Add-Content -Path $outputFile -Value ("Antispyware Enabled: {0}" -f (if ($securityStatus.AntispywareEnabled) { "Enabled" } else { "Disabled" }))
                Add-Content -Path $outputFile -Value ("AMService Enabled: {0}" -f (if ($securityStatus.AMServiceEnabled) { "Enabled" } else { "Disabled" }))
                Add-Content -Path $outputFile -Value ("Quick Scan Age (Days): {0}" -f $securityStatus.QuickScanAge)
                Add-Content -Path $outputFile -Value ("Full Scan Age (Days): {0}" -f $securityStatus.FullScanAge)

                Write-Host "Windows Defender status logged in $logFileName" -ForegroundColor Green
            } catch {
                Write-Host "Failed to retrieve Windows Defender status via Get-MpComputerStatus. Checking alternative method..." -ForegroundColor Yellow
                Add-Content -Path $outputFile -Value "Failed to retrieve Windows Defender status via primary method."
                
                try {
                    $defenderService = Get-Service -Name WinDefend -ErrorAction SilentlyContinue
                    if ($defenderService) {
                        $realtimeProtectionStatus = if ((Get-MpPreference).DisableRealtimeMonitoring -eq $false) { "Enabled" } else { "Disabled" }
                        Add-Content -Path $outputFile -Value ("Windows Defender Antivirus: {0}" -f $realtimeProtectionStatus)
                        Write-Host "Additional Windows Defender settings logged in $logFileName" -ForegroundColor Green
                    } else {
                        Add-Content -Path $outputFile -Value "Windows Defender service not found."
                    }
                } catch {
                    Write-Host "Failed to retrieve Windows Defender status from both methods." -ForegroundColor Red
                    Add-Content -Path $outputFile -Value "Unable to retrieve Windows Defender status using available methods."
                }
            }
        }
    } catch {
        Write-Host "Failed to retrieve security center information." -ForegroundColor Red
        Add-Content -Path $outputFile -Value "Error retrieving security center information."
    }
}

function Log-ProtectionHistory {
    Write-Host "Checking Protection History for recent threats..." -ForegroundColor DarkYellow
    $desktopPath = [System.Environment]::GetFolderPath('Desktop')
    $outputFile = Join-Path -Path $desktopPath -ChildPath $logFileName
    $historyHeader = "`n-----------------`nProtection History:`n"
    Add-Content -Path $outputFile -Value $historyHeader

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
                Add-Content -Path $outputFile -Value "`n"
            }
            Write-Host "Protection history logged in $logFileName" -ForegroundColor Green
        } else {
            Add-Content -Path $outputFile -Value "No recent threats found in Protection History."
            Write-Host "No recent threats found in Protection History." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "Failed to retrieve Protection History." -ForegroundColor Red
        Add-Content -Path $outputFile -Value "Error: Unable to retrieve Protection History."
    }
}

function Log-SystemInfo {
    Write-Host "Logging System Info: Secure Boot status..." -ForegroundColor DarkYellow
    $desktopPath = [System.Environment]::GetFolderPath('Desktop')
    $outputFile = Join-Path -Path $desktopPath -ChildPath $logFileName
    $systemInfoHeader = "`n-----------------`nSystem Info:`n"
    Add-Content -Path $outputFile -Value $systemInfoHeader
    
    try {
        # Check Secure Boot status
        if ((Get-Command -Name Confirm-SecureBootUEFI -ErrorAction SilentlyContinue)) {
            $secureBoot = Confirm-SecureBootUEFI -ErrorAction SilentlyContinue
            $secureBootStatus = if ($secureBoot -eq $true) { "Enabled" } else { "Disabled" }
            Add-Content -Path $outputFile -Value ("Secure Boot: {0}" -f $secureBootStatus)
        } else {
            Add-Content -Path $outputFile -Value "Secure Boot: Not available on this system"
        }
    } catch {
        Write-Host "Could not retrieve Secure Boot status." -ForegroundColor Red
        Add-Content -Path $outputFile -Value "Secure Boot: Unknown (retrieval failed)"
    }

    Write-Host "System Info logged in $logFileName" -ForegroundColor Green
}

# Main execution
$oneDrivePath = Get-OneDrivePath
if ($oneDrivePath) {
    Write-Host "OneDrive path: $oneDrivePath" -ForegroundColor Green
} else {
    Write-Host "OneDrive path could not be determined." -ForegroundColor Yellow
}

function Log-MonitorsEDID {
    Write-Host "`nLogging connected monitor information..." -ForegroundColor DarkYellow
    $desktopPath = [System.Environment]::GetFolderPath('Desktop')
    $outputFile = Join-Path -Path $desktopPath -ChildPath $logFileName
    $header = "`n-----------------`nMonitors and EDID Information:`n"
    Add-Content -Path $outputFile -Value $header

    try {
        $monitors = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID

        if ($monitors) {
            foreach ($monitor in $monitors) {
                $name = ($monitor.UserFriendlyName | ForEach-Object { [char]$_ }) -join ""
                $serial = ($monitor.SerialNumberID | ForEach-Object { [char]$_ }) -join ""
                Add-Content -Path $outputFile -Value ("Monitor Name: {0}, Serial/EDID: {1}" -f $name, $serial)
            }
            Write-Host "Monitor EDID info logged in $logFileName" -ForegroundColor Green
        } else {
            Add-Content -Path $outputFile -Value "No monitor EDID info found."
            Write-Host "No monitor info found." -ForegroundColor Yellow
        }
    } catch {
        Add-Content -Path $outputFile -Value "Error retrieving monitor EDID information."
        Write-Host "Failed to retrieve monitor EDID information." -ForegroundColor Red
    }
}

function Log-PCIeDevices {
    Write-Host "`nLogging PCIe devices..." -ForegroundColor DarkYellow
    $desktopPath = [System.Environment]::GetFolderPath('Desktop')
    $outputFile = Join-Path -Path $desktopPath -ChildPath $logFileName
    $header = "`n-----------------`nPCIe Devices:`n"
    Add-Content -Path $outputFile -Value $header

    try {
        $pcieDevices = Get-PnpDevice | Where-Object { $_.InstanceId -like "PCI*" }

        if ($pcieDevices) {
            foreach ($device in $pcieDevices) {
                Add-Content -Path $outputFile -Value ("Name: {0}, Instance ID: {1}, Status: {2}" -f $device.Name, $device.InstanceId, $device.Status)
            }
            Write-Host "PCIe device info logged in $logFileName" -ForegroundColor Green
        } else {
            Add-Content -Path $outputFile -Value "No PCIe devices found."
            Write-Host "No PCIe devices found." -ForegroundColor Yellow
        }
    } catch {
        Add-Content -Path $outputFile -Value "Error retrieving PCIe devices."
        Write-Host "Error retrieving PCIe device information." -ForegroundColor Red
    }
}

function Log-R6AndSteamBanStatus {
    Write-Host "`nLogging Rainbow Six Siege and Steam account status..." -ForegroundColor DarkYellow
    $desktopPath = [System.Environment]::GetFolderPath('Desktop')
    $outputFile = Join-Path -Path $desktopPath -ChildPath $logFileName
    $header = "`n-----------------`nRainbow Six Siege & Steam Account Status:`n"
    Add-Content -Path $outputFile -Value $header

    $userName = $env:UserName
    $scanResults = @{
        R6Accounts = @()
        SteamAccounts = @()
    }

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

    foreach ($name in ($allUserNames | Sort-Object)) {
        try {
            $url = "https://stats.cc/siege/$name"
            Write-Host "Opening stats for $name on Stats.cc ..." -ForegroundColor Blue
            Start-Process $url
            Start-Sleep -Seconds 0.5
            
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
    Add-Content -Path $outputFile -Value "`nSteam Account Status:`n"
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
            
            Write-Host "Opening Steam profile for $accountName ..." -ForegroundColor Cyan
            $steamUrl = "https://steamcommunity.com/profiles/$steamId"
            Start-Process $steamUrl
            Start-Sleep -Seconds 0.5
            
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

# Execute all functions (Find-SusFiles, Find-RegistrySubkeys, and Log-LogitechScripts removed)
List-BAMStateUserSettings
Log-WindowsInstallDate
Find-RarAndExeFiles
Search-PrefetchFiles
Log-WindowsSecurityStatus
Log-ProtectionHistory
Log-SystemInfo
Log-MonitorsEDID
Log-PCIeDevices
Log-R6AndSteamBanStatus

# Add the USB device scan (no return value to prevent hashtable logging)
Scan-USBDevices

# Final steps
$desktopPath = [System.Environment]::GetFolderPath('Desktop')
$logFilePath = Join-Path -Path $desktopPath -ChildPath $logFileName

if (Test-Path $logFilePath) {
    try {
        Set-Clipboard -Value (Get-Content -Path $logFilePath -Raw) -ErrorAction SilentlyContinue
        Write-Host "Log file copied to clipboard." -ForegroundColor DarkRed
    } catch {
        Write-Host "Failed to copy log file to clipboard." -ForegroundColor Red
    }
} else {
    Write-Host "Log file not found on the desktop." -ForegroundColor Red
}

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

Write-Host "Script execution completed." -ForegroundColor Green
