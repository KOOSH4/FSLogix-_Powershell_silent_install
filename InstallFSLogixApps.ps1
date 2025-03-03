param(
    [string]$StorageAccountName,
    [string]$FileShareName,
    [string]$Secret
)

$storageAccountName = $storageAccountName.Replace("'", "").Trim()
$fileShareName = $fileShareName.Replace("'", "").Trim()
$secret = $secret.Replace("'", "").Trim()

# Test connection to the file server
$FileServer = "$StorageAccountName.file.core.windows.net"
$ProfileShare = "\\$($FileServer)\$FileShareName"
$UserName = "localhost\$StorageAccountName"



# Test connection to the file server
$connectTestResult = Test-NetConnection -ComputerName $FileServer -Port 445
if ($connectTestResult.TcpTestSucceeded) {
    # Save the password so the drive will persist on reboot
    cmd.exe /C "cmdkey /add:`"$FileServer`" /user:`"$UserName`" /pass:`"$Secret`""
    
    # Mount the drive
    New-PSDrive -Name Z -PSProvider FileSystem -Root $ProfileShare -Persist
} else {
    Write-Error -Message "Unable to reach the Azure storage account via port 445. Check to make sure your organization or ISP is not blocking port 445, or use Azure P2S VPN, Azure S2S VPN, or Express Route to tunnel SMB traffic over a different port."
}

# Create the FSLogix registry path if it doesn't exist
New-Item -Path "HKLM:\SOFTWARE" -Name "FSLogix" -ErrorAction Ignore

# Create the Profiles path under FSLogix if it doesn't exist
New-Item -Path "HKLM:\SOFTWARE\FSLogix" -Name "Profiles" -ErrorAction Ignore

# Set ProfilePath and Enabled properties
Set-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" -Name "ProfilePath" -Value $ProfileShare -Force
Set-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" -Name "Enabled" -Value 1 -Force

# Set the VHDLocations property for FSLogix Profiles
Set-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" -Name "VHDLocations" -Value $ProfileShare -Force

# Set other FSLogix properties
Set-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" -Name "DeleteLocalProfileWhenVHDShouldApply" -Value 1 -Force
Set-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" -Name "flipFlopProfileDirectoryName" -Value 1 -Force
Set-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" -Name "IsDynamic" -Value 1 -Force
Set-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" -Name "KeepLocalDir" -Value 0 -Force
Set-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" -Name "profileType" -Value 0 -Force
Set-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" -Name "SizeInMBs" -Value 40000 -Force
Set-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" -Name "VolumeType" -Value "VHDX" -Force
Set-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" -Name "AccessNetworkAsComputerObject" -Value 1 -Force
