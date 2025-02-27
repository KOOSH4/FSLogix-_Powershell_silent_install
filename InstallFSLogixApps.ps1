<#
.SYNOPSIS
    Installs and configures Microsoft FSLogix with proper logging and error handling.
.DESCRIPTION
    This script checks the current version of FSLogix based on the short URL redirected filename
    and installs if FSLogix is not installed, or is older than the currently installed version.
    Includes proper logging, error handling, and registry configuration.
.NOTES
    File Name      : Install-FSLogix.ps1
    Version        : 1.0
#>

# Script parameters - uncomment and define values if not passed from elsewhere
# param(
#    [string]$storageAccountName,
#    [string]$fileShareName,
#    [string]$secret
# )

# Logging function
function Write-Log {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        
        [Parameter(Mandatory=$false)]
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    $logFile = "$env:ProgramData\FSLogixInstall.log"
    
    # Create log directory if it doesn't exist
    $logDir = Split-Path $logFile -Parent
    if (!(Test-Path $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }
    
    # Write to console with color coding
    switch ($Level) {
        "INFO"  { Write-Host $logMessage -ForegroundColor Green }
        "WARN"  { Write-Host $logMessage -ForegroundColor Yellow }
        "ERROR" { Write-Host $logMessage -ForegroundColor Red }
    }
    
    # Append to log file
    $logMessage | Out-File -FilePath $logFile -Append
}

# Validate required parameters
function Test-RequiredParameters {
    $requiredParams = @("storageAccountName", "fileShareName", "secret")
    $missingParams = @()
    
    foreach ($param in $requiredParams) {
        if (-not (Get-Variable -Name $param -ErrorAction SilentlyContinue)) {
            $missingParams += $param
        }
    }
    
    if ($missingParams.Count -gt 0) {
        Write-Log "Missing required parameters: $($missingParams -join ', ')" -Level "ERROR"
        return $false
    }
    
    return $true
}

# FSLogix installation variables
$FSLogixURL = "https://aka.ms/fslogix/download"
$FSLogixDownload = "FSLogixSetup.zip"
$FSLogixInstaller = "FSLogixAppsSetup.exe"
$ZipFileToExtract = "x64/Release/FSLogixAppsSetup.exe"
$Zip = "$env:temp\$FSLogixDownload"
$Installer = "$env:temp\$FSLogixInstaller"
$downloadAndInstall = $false
$ProductName = "Microsoft FSLogix Apps"
$exitCode = 0

Write-Log "Starting FSLogix installation and configuration script" -Level "INFO"

# Parameter validation
if (-not (Test-RequiredParameters)) {
    Write-Log "Required parameters missing. Exiting script." -Level "ERROR"
    exit 1
}

try {
    Write-Log "Checking registry for $ProductName" -Level "INFO"
    
    # Get FSLogix version number if installed
    $fslogixsearch = Get-WmiObject Win32_Product | Where-Object { $_.Name -eq $ProductName } | Select-Object Version
    
    switch ($fslogixsearch.count) {
        0 {
            # Not found
            $fslogixver = $null
            $downloadAndInstall = $true
            Write-Log "FSLogix not found, will download and install" -Level "INFO"
        }
        1 {
            # One entry returned
            $fslogixver = [System.Version]$fslogixsearch.Version
            Write-Log "FSLogix version installed: $fslogixver" -Level "INFO"
        }
        {$_ -gt 1} {
            # two or more returned
            $fslogixver = [System.Version]$fslogixsearch[0].Version
            Write-Log "Multiple FSLogix installations found. Using version: $fslogixver" -Level "WARN"
        }
    }
    
    # Find current FSLogix version from short URL
    try {
        $WebRequest = [System.Net.WebRequest]::create($FSLogixURL)
        $WebResponse = $WebRequest.GetResponse()
        $ActualDownloadURL = $WebResponse.ResponseUri.AbsoluteUri
        $WebResponse.Close()
        
        $FSLogixCurrentVersion = [System.Version]((Split-Path $ActualDownloadURL -leaf).Split("_")[2]).Replace(".zip","")
        Write-Log "Current FSLogix version available: $FSLogixCurrentVersion" -Level "INFO"
        
        # See if the current version is newer than the installed version
        if ($FSLogixCurrentVersion -gt $fslogixver) {
            Write-Log "New version will be downloaded and installed. ($FSLogixCurrentVersion > $fslogixver)" -Level "INFO"
            $downloadAndInstall = $true
        }
    }
    catch {
        Write-Log "Failed to determine current FSLogix version: $_" -Level "ERROR"
        if ($null -eq $fslogixver) {
            Write-Log "Continuing with installation as no FSLogix version is installed" -Level "WARN"
            $downloadAndInstall = $true
        }
        else {
            Write-Log "Keeping existing FSLogix installation" -Level "WARN"
            $downloadAndInstall = $false
        }
    }
    
    # If $downloadAndInstall has been toggled true, download and install
    if ($downloadAndInstall) {
        Write-Log "Beginning FSLogix installation process..." -Level "INFO"
        
        # Download installer
        try {
            Import-Module BitsTransfer -ErrorAction Stop
            Write-Log "Downloading from: $FSLogixURL" -Level "INFO"
            Write-Log "Saving file to: $Zip" -Level "INFO"
            
            Start-BitsTransfer -Source $FSLogixURL -Destination $Zip -RetryInterval 60 -ErrorAction Stop
            Write-Log "Download completed successfully" -Level "INFO"
        }
        catch {
            Write-Log "Failed to download FSLogix: $_" -Level "ERROR"
            exit 1
        }
        
        # Extract file from zip
        try {
            Write-Log "Extracting installer from zip file" -Level "INFO"
            Add-Type -Assembly System.IO.Compression.FileSystem
            $zipFile = [IO.Compression.ZipFile]::OpenRead($Zip)
            
            # Retrieve and extract the needed file
            $filetoextract = ($zipFile.Entries | Where-Object {$_.FullName -eq $ZipFileToExtract})
            
            if ($null -eq $filetoextract -or $filetoextract.Count -eq 0) {
                throw "Required file '$ZipFileToExtract' not found in zip archive"
            }
            
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($filetoextract[0], $Installer, $true)
            Write-Log "Extraction completed successfully" -Level "INFO"
        }
        catch {
            Write-Log "Failed to extract installer: $_" -Level "ERROR"
            if ($null -ne $zipFile) {
                $zipFile.Dispose()
            }
            exit 1
        }
        
        # Run installer
        try {
            Write-Log "Running installer: $Installer /install /quiet /norestart" -Level "INFO"
            $process = Start-Process $Installer -ArgumentList "/install /quiet /norestart" -Wait -PassThru -ErrorAction Stop
            
            # Check exit code
            if ($process.ExitCode -ne 0) {
                Write-Log "Installer exited with code: $($process.ExitCode)" -Level "WARN"
            }
            else {
                Write-Log "Installation completed successfully" -Level "INFO"
            }
            
            # Allow some time for installation to complete
            Write-Log "Waiting for installation to finalize..." -Level "INFO"
            Start-Sleep -Seconds 30
        }
        catch {
            Write-Log "Failed to run installer: $_" -Level "ERROR"
            $exitCode = 1
        }
        
        # Close and clean up
        try {
            if ($null -ne $zipFile) {
                $zipFile.Dispose()
            }
            
            Write-Log "Cleaning up temporary files" -Level "INFO"
            if (Test-Path $Installer) {
                Remove-Item -Path $Installer -Force
            }
            if (Test-Path $Zip) {
                Remove-Item -Path $Zip -Force
            }
        }
        catch {
            Write-Log "Failed during cleanup: $_" -Level "WARN"
        }
    }
    else {
        Write-Log "FSLogix already installed and up to date." -Level "INFO"
    }
    
    # Configure file share and FSLogix settings
    try {
        $fileServer = "$($storageAccountName).file.core.windows.net"
        $profileShare = "\\$($fileServer)\$($fileShareName)\"
        $user = "localhost\$($storageAccountName)"
        
        Write-Log "Configuring access to file share $profileShare" -Level "INFO"
        
        # Store credentials for the file share
        $cmdkeyResult = cmdkey.exe /add:$fileServer /user:$user /pass:$secret
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Failed to store credentials: $cmdkeyResult" -Level "ERROR"
            $exitCode = 1
        }
        else {
            Write-Log "Credentials stored successfully" -Level "INFO"
        }
        
        # Ensure FSLogix registry paths exist
        $registryPath = "HKLM:\SOFTWARE\FSLogix\Profiles"
        if (!(Test-Path $registryPath)) {
            New-Item -Path $registryPath -Force | Out-Null
            Write-Log "Created registry path: $registryPath" -Level "INFO"
        }
        
        # Configure FSLogix registry settings
        Write-Log "Configuring FSLogix registry settings" -Level "INFO"
        New-ItemProperty -Path $registryPath -Name "Enabled" -Value "1" -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $registryPath -Name "VHDLocations" -Value $profileShare -Force | Out-Null
        New-ItemProperty -Path $registryPath -Name "AccessNetworkAsComputerObject" -Value 1 -Force | Out-Null
        
        # Add additional settings
        New-ItemProperty -Path $registryPath -Name "DeleteLocalProfileWhenVHDShouldApply" -Value 1 -Force | Out-Null
        New-ItemProperty -Path $registryPath -Name "FlipFlopProfileDirectoryName" -Value 1 -Force | Out-Null
        New-ItemProperty -Path $registryPath -Name "VolumeType" -Value "VHDX" -PropertyType String -Force | Out-Null
        
        Write-Log "FSLogix configuration completed successfully" -Level "INFO"
    }
    catch {
        Write-Log "Failed to configure FSLogix: $_" -Level "ERROR"
        $exitCode = 1
    }
    
    Write-Log "Script execution completed with exit code: $exitCode" -Level "INFO"
    exit $exitCode
}
catch {
    Write-Log "Unhandled exception: $_" -Level "ERROR"
    exit 1
}