# Import the Active Directory module
Import-Module ActiveDirectory

# Define the path to the Excel file and log file
$excelPath = "C:\Users\azureuser\Desktop\sampleADUsers.xlsx"
$logPath = Join-Path (Split-Path -Parent $excelPath) "ADImportLog.txt"

# Import the Excel file
$users = Import-Excel -Path $excelPath

# Function to write log with timestamp
function Write-Log {
    Param ([string]$message)
    Add-Content -Path $logPath -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'): $message"
}

# Process each user
foreach ($user in $users) {
    $username = $user.Username
    $firstName = $user.FirstName
    $lastName = $user.LastName
    $department = $user.department
    $groupName = "${department}users"
    $password = $user.credential | ConvertTo-SecureString -AsPlainText -Force

    try {
        # Check if the group exists, if not, create it
        $group = Get-ADGroup -Filter "Name -eq '$groupName'" -ErrorAction SilentlyContinue
        if (-not $group) {
            New-ADGroup -Name $groupName -GroupScope Global -Path "OU=Groups,DC=vlab,DC=local"
            Write-Log "Group '$groupName' created."
        }

        # Check if the user exists, if not, create the user
        $adUser = Get-ADUser -Filter "SamAccountName -eq '$username'" -ErrorAction SilentlyContinue
        if (-not $adUser) {
            New-ADUser -SamAccountName $username -Name "$firstName $lastName" -GivenName $firstName -Surname $lastName -Department $department -AccountPassword $password -Enabled $true
            Write-Log "User '$username' created."
        }

        # Add the user to the group
        Add-ADGroupMember -Identity $groupName -Members $username -ErrorAction SilentlyContinue
        Write-Log "User '$username' added to group '$groupName'."
    } catch {
        Write-Log "An error occurred for user '$username': $_"
    }
}
