<#
.SYNOPSIS
    Downloads and installs FSLogix and configures it to work with Azure Files.
.DESCRIPTION
    This script downloads the latest version of FSLogix from Microsoft, extracts it, installs it silently,
    and configures it to use an Azure Files share for profile storage.
.PARAMETER storageAccountName
    The name of the Azure Storage Account where FSLogix profiles will be stored.
.PARAMETER fileShareName
    The name of the file share in the Azure Storage Account.
.PARAMETER secret
    The primary access key for the Azure Storage Account.
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$storageAccountName,
    
    [Parameter(Mandatory=$true)]
    [string]$fileShareName,
    
    [Parameter(Mandatory=$true)]
    [string]$secret
)

# Set error action preference to stop
$ErrorActionPreference = "Stop"

# Log file path
$logFile = "C:\Windows\Temp\FSLogixInstall_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-Log {
    param(
        [string]$message
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $message" | Out-File -FilePath $logFile -Append
    Write-Host "$timestamp - $message"
}

# Clean parameters of any single quotes that might have been passed from Terraform
$storageAccountName = $storageAccountName.Replace("'", "").Trim()
$fileShareName = $fileShareName.Replace("'", "").Trim()
$secret = $secret.Replace("'", "").Trim()

Write-Log "Starting FSLogix installation and configuration"
Write-Log "Storage Account (cleaned): $storageAccountName"
Write-Log "File Share (cleaned): $fileShareName"

# Create temp directory if it doesn't exist
$tempDir = Join-Path $env:TEMP "FSLogixInstall"
if (!(Test-Path $tempDir)) {
    New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
    Write-Log "Created temporary directory: $tempDir"
}

# Define FSLogix variables
$FSLogixURL = "https://aka.ms/fslogix/download"
$FSLogixDownload = "FSLogixSetup.zip"
$ZipFileToExtract = "x64/Release/FSLogixAppsSetup.exe"
$Zip = Join-Path $tempDir $FSLogixDownload
$Installer = Join-Path $tempDir "FSLogixAppsSetup.exe"

# Check for existing installation
$fslogixInstalled = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue | 
                    Where-Object { $_.DisplayName -like "*FSLogix Apps*" }
if ($fslogixInstalled) {
    Write-Log "FSLogix is already installed. Version: $($fslogixInstalled.DisplayVersion)"
    $downloadAndInstall = $false
} else {
    Write-Log "FSLogix is not installed. Proceeding with download and installation."
    $downloadAndInstall = $true
}

if ($downloadAndInstall) {
    # Download FSLogix
    try {
        Write-Log "Downloading FSLogix from $FSLogixURL"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'  # Hide progress bar for faster download
        Invoke-WebRequest -Uri $FSLogixURL -OutFile $Zip -UseBasicParsing
        Write-Log "Download completed successfully"
    } catch {
        Write-Log "Error downloading FSLogix: $_"
        throw "Failed to download FSLogix"
    }

    # Extract FSLogix installer
    try {
        Write-Log "Extracting FSLogix installer from zip file"
        
        # Ensure the System.IO.Compression.FileSystem assembly is loaded
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
        } catch {
            Write-Log "Unable to load System.IO.Compression.FileSystem. Using Expand-Archive instead."
        }
        
        # Try to extract using ZipFile class first
        try {
            $zip = [System.IO.Compression.ZipFile]::OpenRead($Zip)
            $entry = $zip.Entries | Where-Object { $_.FullName -eq $ZipFileToExtract }
            
            if ($entry -eq $null) {
                Write-Log "Error: Could not find $ZipFileToExtract in the zip file"
                $zip.Dispose()
                throw "Required file not found in zip package"
            }
            
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $Installer, $true)
            $zip.Dispose()
        } catch {
            Write-Log "Using alternative extraction method: Expand-Archive"
            # Extract to a temporary folder and then move the specific file
            $extractPath = Join-Path $tempDir "Extract"
            Expand-Archive -Path $Zip -DestinationPath $extractPath -Force
            $extractedInstaller = Join-Path $extractPath $ZipFileToExtract
            
            if (!(Test-Path $extractedInstaller)) {
                Write-Log "Error: Could not find $ZipFileToExtract in the extracted files"
                throw "Required file not found in extracted package"
            }
            
            Copy-Item -Path $extractedInstaller -Destination $Installer -Force
            Write-Log "Extracted using Expand-Archive successfully"
        }
        
        Write-Log "Extraction completed successfully"
    } catch {
        Write-Log "Error extracting FSLogix installer: $_"
        throw "Failed to extract FSLogix installer"
    }

    # Install FSLogix
    try {
        Write-Log "Installing FSLogix silently"
        $process = Start-Process -FilePath $Installer -ArgumentList "/quiet /norestart" -PassThru -Wait -NoNewWindow
        $exitCode = $process.ExitCode
        
        if ($exitCode -ne 0) {
            Write-Log "Error: FSLogix installation failed with exit code $exitCode"
            throw "FSLogix installation failed with exit code $exitCode"
        }
        Write-Log "FSLogix installation completed successfully"
    } catch {
        Write-Log "Error during FSLogix installation: $_"
        throw "Failed to install FSLogix"
    }
}

# Give FSLogix services a moment to initialize
Start-Sleep -Seconds 10

# Configure FSLogix to use Azure Files
try {
    Write-Log "Configuring FSLogix to use Azure Files"
    
    # Ensure required registry keys exist
    $regPath = "HKLM:\SOFTWARE\FSLogix\Profiles"
    if (!(Test-Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
        Write-Log "Created registry path: $regPath"
    }
    
    # Set the profile share path with cleaned parameters
    $profileShare = "\\$storageAccountName.file.core.windows.net\$fileShareName"
    Write-Log "Setting profile share to: $profileShare"
    
    # Configure FSLogix registry settings
    Set-ItemProperty -Path $regPath -Name "Enabled" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $regPath -Name "VHDLocations" -Value $profileShare -Force
    Set-ItemProperty -Path $regPath -Name "AccessNetworkAsComputerObject" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $regPath -Name "DeleteLocalProfileWhenVHDShouldApply" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $regPath -Name "FlipFlopProfileDirectoryName" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $regPath -Name "VolumeType" -Value "VHDX" -Type String -Force
    Set-ItemProperty -Path $regPath -Name "SizeInMBs" -Value 30000 -Type DWord -Force  # 30GB default size
    
    Write-Log "FSLogix registry configuration completed"
    
    # Test connectivity and configure storage account credentials
    Write-Log "Testing connectivity to Azure Files share on port 445"
    $connectTestResult = Test-NetConnection -ComputerName "$storageAccountName.file.core.windows.net" -Port 445
    if ($connectTestResult.TcpTestSucceeded) {
        Write-Log "Port 445 connectivity test succeeded to $storageAccountName.file.core.windows.net"
        
        # Build the cmdkey command with the proper quoting
        $cmdkeyCommand = "cmd.exe /C "cmdkey /add:`"$($storageAccountName).file.core.windows.net`" /user:`"localhost\$($storageAccountName)`" /pass:`"$secret`""
        Write-Log "Executing cmdkey command: $cmdkeyCommand"
        $cmdkeyResult = Invoke-Expression $cmdkeyCommand
        Write-Log "cmdkey result: $cmdkeyResult"
        
        # Mount the drive to verify connectivity
        try {
            $driveLetter = "Z:"
            Write-Log "Attempting to mount drive $driveLetter for connectivity test"
            New-PSDrive -Name Z -PSProvider FileSystem -Root "\\$storageAccountName.file.core.windows.net\$fileShareName" -Persist -ErrorAction Stop
            Write-Log "Drive $driveLetter mapped successfully"
            # Optionally remove the drive mapping after testing if persistent mapping is not desired.
            Remove-PSDrive -Name Z -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Log "Drive mapping test failed: $_"
        }
    } else {
        Write-Error "Unable to reach $storageAccountName.file.core.windows.net via port 445. Check that your organization or ISP is not blocking port 445, or consider using a VPN/tunneling solution."
    }
    
    # Test connection to verify if the share is accessible
    try {
        Write-Log "Testing direct connection to Azure Files share"
        $testContent = "Testing connection at $(Get-Date)"
        $testFile = "test-connection-$(Get-Random).txt"
        $directPath = "\\$storageAccountName.file.core.windows.net\$fileShareName\$testFile"
        $testContent | Out-File -FilePath $directPath -Force -ErrorAction Stop
        Write-Log "Successfully verified connection to Azure file share using direct path"
        Remove-Item -Path $directPath -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Log "Direct path connection failed: $_"
        Write-Log "FSLogix configuration will continue but may not work until connectivity issues are resolved"
    }
    
} catch {
    Write-Log "Error configuring FSLogix: $_"
    throw "Failed to configure FSLogix"
}

# Clean up temporary files
try {
    Write-Log "Cleaning up temporary files"
    if (Test-Path $Zip) { Remove-Item $Zip -Force }
    Write-Log "Cleanup completed"
} catch {
    Write-Log "Warning: Failed to clean up temporary files: $_"
}

# Restart FSLogix service to apply changes
try {
    $fslogixService = Get-Service -Name "frxsvc" -ErrorAction SilentlyContinue
    if ($fslogixService) {
        Write-Log "Restarting FSLogix service"
        Restart-Service -Name "frxsvc" -Force
        Write-Log "FSLogix service restarted"
    } else {
        Write-Log "Warning: FSLogix service not found. This may indicate a problem with the installation."
    }
} catch {
    Write-Log "Warning: Failed to restart FSLogix service: $_"
}

Write-Log "FSLogix installation and configuration completed successfully"
Write-Log "Profile share is configured to: $profileShare"
Write-Log "Installation completed at $(Get-Date)"
