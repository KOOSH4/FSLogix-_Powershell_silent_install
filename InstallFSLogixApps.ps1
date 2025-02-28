param(
    [Parameter(Mandatory=$true)]
    [string]$storageAccountName,
    [Parameter(Mandatory=$true)]
    [string]$fileShareName,
    [Parameter(Mandatory=$true)]
    [string]$secret
)

$FSLogixURL = "https://aka.ms/fslogix/download"
$FSLogixDownload = "FSLogixSetup.zip"
$FSLogixInstaller = "FSLogixAppsSetup.exe"
$ZipFileToExtract = "x64/Release/FSLogixAppsSetup.exe"
$Zip = Join-Path $env:TEMP $FSLogixDownload
$Installer = Join-Path $env:TEMP $FSLogixInstaller
$downloadAndInstall = $false

$ProductName = "Microsoft FSLogix Apps"
Write-Host "Checking registry for $ProductName"

# Retrieve installed FSLogix version using registry (avoid slow Win32_Product)
try {
    $regPathUninstall = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    $installedFSLogix = Get-ChildItem $regPathUninstall | Where-Object { $_.GetValue("DisplayName") -eq $ProductName }
    if ($null -eq $installedFSLogix) {
        $fslogixver = [version]"0.0.0.0"
        $downloadAndInstall = $true
    }
    else {
        $fslogixverString = $installedFSLogix | Select-Object -ExpandProperty "DisplayVersion" -First 1
        $fslogixver = [version]$fslogixverString
        Write-Host "FSLogix version installed: $fslogixver"
    }
}
catch {
    Write-Host "Error retrieving installed version: $_"
    $fslogixver = [version]"0.0.0.0"
    $downloadAndInstall = $true
}

# Get current FSLogix version from the redirect URL
try {
    $WebRequest = [System.Net.WebRequest]::Create($FSLogixURL)
    $WebResponse = $WebRequest.GetResponse()
    $ActualDownloadURL = $WebResponse.ResponseUri.AbsoluteUri
    $WebResponse.Close()

    $fileName = Split-Path $ActualDownloadURL -Leaf
    # Expected format: FSLogix_Apps_2.9.8440.42104.zip
    $versionPart = (($fileName -split "_")[2] -replace "\.zip$","")
    $FSLogixCurrentVersion = [version]$versionPart
    Write-Host "Current FSLogix version available: $FSLogixCurrentVersion"
}
catch {
    Write-Host "Error retrieving current version: $_"
    exit 1
}

if ($FSLogixCurrentVersion -gt $fslogixver) {
    Write-Host "New version available ($FSLogixCurrentVersion) is newer than installed version ($fslogixver)."
    $downloadAndInstall = $true
}
else {
    Write-Host "Installed version is up-to-date."
}

if ($downloadAndInstall) {
    Write-Host "Proceeding with FSLogix installation..."

    # Download installer using BITS
    try {
        Import-Module BitsTransfer -ErrorAction Stop
        Write-Host "Downloading FSLogix from: $FSLogixURL"
        Write-Host "Saving to: $Zip"
        Start-BitsTransfer -Source $FSLogixURL -Destination $Zip -RetryInterval 60 -ErrorAction Stop
    }
    catch {
        Write-Host "Error downloading FSLogix: $_"
        exit 1
    }

    # Extract the installer from the zip archive
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zipFile = [IO.Compression.ZipFile]::OpenRead($Zip)
        $fileToExtract = $zipFile.Entries | Where-Object { $_.FullName -eq $ZipFileToExtract }
        if ($fileToExtract) {
            [IO.Compression.ZipFileExtensions]::ExtractToFile($fileToExtract, $Installer, $true)
            Write-Host "Extraction successful: $Installer"
        }
        else {
            Write-Host "Error: Could not find $ZipFileToExtract in the zip archive."
            $zipFile.Dispose()
            exit 1
        }
        $zipFile.Dispose()
    }
    catch {
        Write-Host "Error extracting FSLogix installer: $_"
        exit 1
    }

    # Run installer
    try {
        Write-Host "Running installer: $Installer /install /quiet /norestart"
        Start-Process -FilePath $Installer -ArgumentList "/install", "/quiet", "/norestart" -Wait -ErrorAction Stop
    }
    catch {
        Write-Host "Error during installation: $_"
        exit 1
    }

    # Allow time for installer processes to fully exit
    Start-Sleep -Seconds 300

    # Clean up downloaded files
    Write-Host "Cleaning up installer files."
    Remove-Item -Path $Installer -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $Zip -Force -ErrorAction SilentlyContinue
}
else {
    Write-Host "No installation required."
}

# Configure FSLogix settings

# Build the file server FQDN and profile share path
$fileServer = "$storageAccountName.file.core.windows.net"
$profileShare = "\\$fileServer\userprofiles"

# Add credentials for file share access
$user = "localhost\$storageAccountName"
Write-Host "Setting up file share credentials for $fileServer"
cmdkey.exe /add:$fileServer /user:$user /pass:$secret

# Configure registry settings for FSLogix Profiles
$regPath = "HKLM:\SOFTWARE\FSLogix\Profiles"
if (-not (Test-Path $regPath)) {
    New-Item -Path "HKLM:\SOFTWARE\FSLogix" -Name "Profiles" -Force | Out-Null
}

Write-Host "Configuring FSLogix registry settings..."
Set-ItemProperty -Path $regPath -Name "Enabled" -Value 1 -Type DWord -Force
Set-ItemProperty -Path $regPath -Name "VHDLocations" -Value $profileShare -Force
Set-ItemProperty -Path $regPath -Name "AccessNetworkAsComputerObject" -Value 1 -Force
Set-ItemProperty -Path $regPath -Name "DeleteLocalProfileWhenVHDShouldApply" -Value 1 -Force
Set-ItemProperty -Path $regPath -Name "FlipFlopProfileDirectoryName" -Value 1 -Force
Set-ItemProperty -Path $regPath -Name "VolumeType" -Value "VHDX" -Type String -Force

# Restart the FSLogix service to apply changes
try {
    Write-Host "Restarting FSLogix service..."
    Restart-Service -Name "frxsvc" -Force -ErrorAction Stop
}
catch {
    Write-Host "Error restarting FSLogix service: $_"
}
