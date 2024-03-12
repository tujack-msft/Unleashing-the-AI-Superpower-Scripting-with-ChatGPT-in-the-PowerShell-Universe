# Variables
$resourceGroupName = "PeeringRGB"
$originalVmName = "OrigVM4clone"
$newVmName = "ClonedVM-linux"
$location = "eastus" # Example: "eastus"
$logFilePath = "c:\users\tujack\documents\logFile.txt"

# Function to log messages to a file
function Write-Log {
    Param ([string]$message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content $logFilePath -Value "${timestamp}: $message"
}

# Function to handle errors and log them
function Handle-Error {
    Param ([string]$message)
    Write-Log "ERROR: $message"
    Write-Log "Exception Message: $($_.Exception.Message)"
    Write-Log "Exception Item: $($_.Exception.ItemName)"
    return
}

# Initialize a hashtable to keep track of created resources
$createdResources = @{
    "publicIp" = $null
    "nics" = @()
    "osDisk" = $null
    "dataDisks" = @()
    "vm" = $false
}

# Start logging
Write-Log "=============Start the process to clone VM $originalVmName to $newVmName.=============== "

try {
    # Get the original VM
    Write-Log "Attempting to retrieve original VM details"
    $originalVm = Get-AzVM -Name $originalVmName -ResourceGroupName $resourceGroupName
    $vmsize = $originalVm.HardwareProfile.VmSize
    Write-Log "Retrieved original VM details: $($originalVm.Name)"
    Write-Log "VMsize: $vmsize"
    Write-Log "Location: $location"
    $AvZone = $originalVm.Zones
    Write-Log "The Availability Zone of the VM $originalVmName is: $AvZone"

    # Create snapshots of all disks
    Write-Log "Attempting to create snapshots of all disks"
    $allDisks = $originalVm.StorageProfile.DataDisks + $originalVm.StorageProfile.OsDisk
    foreach ($disk in $allDisks) {
        Write-Log "Processing disk: $($disk.Name)"
        $snapshotConfig = New-AzSnapshotConfig -SourceUri $disk.ManagedDisk.Id -Location $location  -CreateOption Copy
        $snapshotName = "snapshot-" + $disk.Name
        Write-Log "Attempting to create snapshot: $snapshotName"
        New-AzSnapshot -Snapshot $snapshotConfig -SnapshotName $snapshotName -ResourceGroupName $resourceGroupName
        Write-Log "Created snapshot for disk: $($disk.Name)"
    }

    # Create new disks from the snapshots
    $osDiskSnapshot = Get-AzSnapshot -SnapshotName ("snapshot-" + $originalVm.StorageProfile.OsDisk.Name) -ResourceGroupName $resourceGroupName
    # Check if $AvZone is 1, 2, or 3 and assign $newOsDiskConfig accordingly
    if ($AvZone -eq 1 -or $AvZone -eq 2 -or $AvZone -eq 3) {
        Write-Log "Creating new OS disk with Availability Zone: $AvZone"
        $newOsDiskConfig = New-AzDiskConfig -Location $location -SourceResourceId $osDiskSnapshot.Id -Zone $AvZone -CreateOption Copy
    } else {
        Write-Log "Creating new OS disk without specifying an Availability Zone"
        $newOsDiskConfig = New-AzDiskConfig -Location $location -SourceResourceId $osDiskSnapshot.Id -CreateOption Copy
    }
    $newOsDisk = New-AzDisk -Disk $newOsDiskConfig -DiskName ($newVmName + "_osDisk") -ResourceGroupName $resourceGroupName
    $createdResources["osDisk"] = $newOsDisk
    Write-Log "Created new OS disk from snapshot"

    $dataDisks = @()
    foreach ($dataDiskSnapshot in $originalVm.StorageProfile.DataDisks) {
        $snapshot = Get-AzSnapshot -SnapshotName ("snapshot-" + $dataDiskSnapshot.Name) -ResourceGroupName $resourceGroupName
        if ($AvZone -eq 1 -or $AvZone -eq 2 -or $AvZone -eq 3) {
            Write-Log "Creating data disk with Availability Zone: $AvZone"
            $newDataDiskConfig = New-AzDiskConfig -Location $location -SourceResourceId $snapshot.Id -Zone $AvZone -CreateOption Copy
        } else {
            Write-Log "Creating new OS disk without specifying an Availability Zone"
            $newDataDiskConfig = New-AzDiskConfig -Location $location -SourceResourceId $snapshot.Id -CreateOption Copy
        }
        
        $newDataDisk = New-AzDisk -Disk $newDataDiskConfig -DiskName ($newVmName + "_" + $dataDiskSnapshot.Name) -ResourceGroupName $resourceGroupName
        $dataDisks += @{
            Disk = $newDataDisk
            Lun = $dataDiskSnapshot.Lun
        }
        $createdResources["dataDisks"] += $newDataDisk
        Write-Log "Created new data disk from snapshot: $($dataDiskSnapshot.Name)"
    }

    # Create new NICs for the new VM
$newNics = @()
$numofnics= $originalVm.NetworkProfile.NetworkInterfaces.count
$number = [int]$numofnics
Write-Log "Original VM have $number  NIC card"
$orignicId = $originalVm.NetworkProfile.NetworkInterfaces[0].Id
$orignic = Get-AzNetworkInterface -ResourceId $orignicId
$vnet = $orignic.IpConfigurations[0].Subnet.Id.Split('/')[-3]
$subnet = $orignic.IpConfigurations[0].Subnet.Id.Split('/')[-1]
Write-Log "Original VM is in subnet $subnet, under virtual network $vnet. "
# Retrieve the network interface of the original VM
$originalNic = Get-AzNetworkInterface -ResourceGroupName $originalVm.ResourceGroupName | Where-Object { $_.VirtualMachine.Id -eq $originalVm.Id }

# Check if the original network interface has a public IP association
$originalPublicIp = $originalNic.IpConfigurations | Where-Object { $_.PublicIpAddress -ne $null }

# If the original VM has a public IP, then create and associate a new public IP to the target VM
if ($originalPublicIp) {
    # Create a public IP address for the target VM
    Write-Log "Detected that original VM $originalVmName have Public Ip, now creating Public Ip for target VM. "
    $publicIpName = "$newVmName-ip"
    $publicIp = New-AzPublicIpAddress -Name $publicIpName -ResourceGroupName $originalVm.ResourceGroupName -Location $originalVm.Location -AllocationMethod Static
    Write-Log "Public Ip $publicip has been created for target cloned vm $newVmName. "
    $createdResources["publicIp"] = $publicIp

    # Create the network interface with the public IP for the target VM
    $primaryNicName = "$newVmName-nic0"
    $primaryNic = New-AzNetworkInterface -ResourceGroupName $originalVm.ResourceGroupName -Location $originalVm.Location -Name $primaryNicName -SubnetId $originalNic.IpConfigurations[0].Subnet.Id -PublicIpAddressId $publicIp.Id
    $primaryNic.Primary = $true
    $newNics += $primaryNic
    Write-Log "Network Interface $primaryNicName has been created for target cloned vm $newVmName. "
    # Now you can proceed to create the target VM with the $targetNic network interface which includes the public IP
    # ...
} else {
    # If the original VM does not have a public IP, create the network interface without a public IP for the target VM
    $primaryNicName = "$newVmName-nic0"
    try {
        $primaryNic = New-AzNetworkInterface -ResourceGroupName $originalVm.ResourceGroupName -Location $originalVm.Location -Name $primaryNicName -SubnetId $originalNic.IpConfigurations[0].Subnet.Id
    } catch {
        Handle-Error "Failed to create network interface '$primaryNic'."
        continue
    }    
    $newNics += $primaryNic
        Write-Log "Network Interface $primaryNicName has been created for target cloned vm $newVmName. "
    # Now you can proceed to create the target VM with the $targetNic network interface which does not include a public IP

}

for ($i = 1; $i -lt $number; $i++) {
    $otherNicName = "$newVmName-nic$i"
    try {
        $otherNic =  New-AzNetworkInterface -ResourceGroupName $originalVm.ResourceGroupName -Location $originalVm.Location -Name $otherNicName -SubnetId $originalNic.IpConfigurations[0].Subnet.Id
    } catch {
        Handle-Error "Failed to create network interface '$otherNic'."
        continue
    }
    $newNics += $otherNic
    Write-Log "Network Interface $otherNicName has been created for target cloned vm $newVmName. "
}
    $createdResources["nics"] = $newNics    

    # Create the new VM configuration
    $newVmConfig = New-AzVMConfig -VMName $newVmName -VMSize $originalVm.HardwareProfile.VmSize
    if ($originalVm.StorageProfile.OsDisk.OsType -eq "Windows") {
        $newVmConfig = Set-AzVMOSDisk -VM $newVmConfig -ManagedDiskId $newOsDisk.Id -CreateOption Attach -Windows
    } else {
        $newVmConfig = Set-AzVMOSDisk -VM $newVmConfig -ManagedDiskId $newOsDisk.Id -CreateOption Attach -Linux
    }
    foreach ($dataDiskMapping in $dataDisks) {
        $newVmConfig = Add-AzVMDataDisk -VM $newVmConfig -Name $dataDiskMapping.Disk.Name -ManagedDiskId $dataDiskMapping.Disk.Id -CreateOption Attach -Lun $dataDiskMapping.Lun
    }
    $isPrimarySet = $false
    foreach ($newNic in $newNics) {
        if (-not $isPrimarySet) {
            $newVmConfig = Add-AzVMNetworkInterface -VM $newVmConfig -Id $newNic.Id -Primary
            $isPrimarySet = $true
        } else {
            $newVmConfig = Add-AzVMNetworkInterface -VM $newVmConfig -Id $newNic.Id
        }
    }
    Write-Log "Configured new VM"

    # Create the new VM
    New-AzVM -ResourceGroupName $resourceGroupName -Location $location -VM $newVmConfig
    $createdResources["vm"] = $true
    Write-Log "Successfully created new VM: $newVmName"
} catch {
    Handle-Error "An error occurred during the VM clone process."

    # Cleanup logic for created resources
    Write-Log "An error occurred. Starting cleanup of created resources."

    # Clean up public IP if it was created
    if ($createdResources["publicIp"] -ne $null) {
        Remove-AzPublicIpAddress -Name $createdResources["publicIp"].Name -ResourceGroupName $resourceGroupName -Force
        Write-Log "Deleted public IP address: $($createdResources["publicIp"].Name)"
    }

    # Clean up network interfaces if they were created
    foreach ($nic in $createdResources["nics"]) {
        Remove-AzNetworkInterface -Name $nic.Name -ResourceGroupName $resourceGroupName -Force
        Write-Log "Deleted network interface: $($nic.Name)"
    }

    # Clean up disks if they were created
    if ($createdResources["osDisk"] -ne $null) {
        Remove-AzDisk -DiskName $createdResources["osDisk"].Name -ResourceGroupName $resourceGroupName -Force
        Write-Log "Deleted OS disk: $($createdResources["osDisk"].Name)"
    }
    foreach ($dataDisk in $createdResources["dataDisks"]) {
        Remove-AzDisk -DiskName $dataDisk.Name -ResourceGroupName $resourceGroupName -Force
        Write-Log "Deleted data disk: $($dataDisk.Name)"
    }
} finally {
    # This block will run whether or not there was an error
    if (-not $createdResources["vm"]) {
        Write-Log "Starting cleanup process to delete snapshots."
        $snapshotPrefix = "snapshot-"
        try {
            # Attempt to delete snapshots for OS disk and data disks
            $osSnapshotName = $snapshotPrefix + $originalVm.StorageProfile.OsDisk.Name
            Remove-AzSnapshot -SnapshotName $osSnapshotName -ResourceGroupName $resourceGroupName -Force
            Write-Log "Deleted OS disk snapshot: $osSnapshotName"

            foreach ($dataDisk in $originalVm.StorageProfile.DataDisks) {
                $dataSnapshotName = $snapshotPrefix + $dataDisk.Name
                Remove-AzSnapshot -SnapshotName $dataSnapshotName -ResourceGroupName $resourceGroupName -Force
                Write-Log "Deleted data disk snapshot: $dataSnapshotName"
            }
        } catch {
            # Log an error if the cleanup fails
            Write-Log "An error occurred during the cleanup process."
            Write-Log "Exception Message: $($_.Exception.Message)"
        }
    }
    Write-Log "Cleanup process completed."
}
