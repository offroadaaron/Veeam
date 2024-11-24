# Created by offroadaaron
# Permissions
# vCenter - Read-Only
# Veeam - Backup Viewer

# Load Veeam PowerShell Snap-in
Add-PSSnapin -Name VeeamPSSnapin -ErrorAction SilentlyContinue

# Configure PowerCLI to ignore invalid SSL certificates
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false

# Hardcoded credentials (Replace with actual username and password)
$vcUsername = "your_vcenter_username"  # Replace with your vCenter username
$vcPassword = "your_vcenter_password"  # Replace with your vCenter password

# Create a secure credential object
$vcSecurePassword = ConvertTo-SecureString -String $vcPassword -AsPlainText -Force
$vcCredentials = New-Object System.Management.Automation.PSCredential ($vcUsername, $vcSecurePassword)

# Connect to vCenter server using the hardcoded credentials
$vcServer = "your_vcenter_server"  # Replace with your vCenter server name or IP
Connect-VIServer -Server $vcServer -Credential $vcCredentials

# Connect to Veeam Backup Server
$veeamServer = "your_veeam_server"  # Replace with your Veeam server hostname or IP
$veeamUsername = "your_veeam_username"  # Replace with your Veeam username
$veeamPassword = "your_veeam_password"  # Replace with your Veeam password
$veeamSecurePassword = ConvertTo-SecureString -String $veeamPassword -AsPlainText -Force
$veeamCredentials = New-Object System.Management.Automation.PSCredential ($veeamUsername, $veeamSecurePassword)
Connect-VBRServer -Server $veeamServer -Credential $veeamCredentials

# Get all VMs from vCenter
$allVMs = Get-VM

# Filter Veeam backups (Example: Adjust according to your job names or requirements)
$backups = Get-VBRBackup | Where-Object { $_.JobName -like "All*" }

# Initialize an empty array to hold the result
$vmBackupInfo = @()

# Loop through each VM in vCenter and get its backup info from Veeam
foreach ($vm in $allVMs) {
    # Get the VM name from vCenter
    $vmName = $vm.Name
    
    # Attempt to get all restore points for the VM from the filtered Veeam backups
    $restorePoints = $backups | ForEach-Object { $_ | Get-VBRRestorePoint } | Where-Object { $_.Name -eq $vmName }

    # Count the number of restore points
    $restorePointCount = $restorePoints.Count

    # Collect restore point dates as a list (formatted as Australian standard)
    $restorePointDates = $restorePoints | Sort-Object CreationTime | ForEach-Object {
        $_.CreationTime.ToString("dd/MM/yyyy HH:mm:ss")
    }

    # Combine restore point dates into a single string, separated by commas
    $restorePointDatesFormatted = $restorePointDates -join ", "

    # If there are restore points, grab the latest backup date; otherwise, mark as 'Never'
    if ($restorePoints) {
        $lastBackup = ($restorePoints | Sort-Object CreationTime -Descending | Select-Object -First 1).CreationTime.ToString("dd/MM/yyyy HH:mm:ss")
    } else {
        $lastBackup = "Never"
    }

    # Store the result in the array
    $vmBackupInfo += [PSCustomObject]@{
        VMName             = $vmName
        LastBackup         = $lastBackup
        RestorePointCount  = $restorePointCount
        RestorePointDates  = $restorePointDatesFormatted
    }
}

# Disconnect from vCenter server
Disconnect-VIServer -Server $vcServer -Confirm:$false

# Disconnect from Veeam Backup & Replication Server
Disconnect-VBRServer

# Generate HTML Output
$htmlReportPath = "C:\VMBackupReport.html"  # Specify the output path for the HTML file

# Define CSS and JavaScript for filtering
$css = @"
<style>
    table {
        border-collapse: collapse;
        width: 100%;
    }
    th, td {
        border: 1px solid #ddd;
        padding: 8px;
    }
    th {
        padding-top: 12px;
        padding-bottom: 12px;
        text-align: left;
        background-color: #4CAF50;
        color: white;
    }
    tr:nth-child(even) {background-color: #f2f2f2;}
    tr:hover {background-color: #ddd;}
    details summary {
        cursor: pointer;
        font-weight: bold;
    }
    details summary:hover {
        color: #4CAF50;
    }
    input[type="text"] {
        margin-bottom: 12px;
        padding: 8px;
        width: 100%;
        box-sizing: border-box;
    }
</style>
"@

$javascript = @"
<script>
    function filterTable() {
        var input = document.getElementById('searchInput');
        var filter = input.value.toUpperCase();
        var table = document.getElementById('vmBackupTable');
        var tr = table.getElementsByTagName('tr');
        
        for (var i = 1; i < tr.length; i++) {
            var td = tr[i].getElementsByTagName('td');
            var match = false;
            for (var j = 0; j < td.length; j++) {
                if (td[j] && td[j].innerText.toUpperCase().indexOf(filter) > -1) {
                    match = true;
                    break;
                }
            }
            tr[i].style.display = match ? '' : 'none';
        }
    }
</script>
"@

# Build HTML table rows manually with restore points as dropdowns
$htmlRows = foreach ($vm in $vmBackupInfo) {
    # Create a dropdown for restore point dates
    $restorePointDropdown = if ($vm.RestorePointDates) {
        # Split the restore point dates and wrap each date in <li> tags
        $restorePointItems = ($vm.RestorePointDates -split ", ") | ForEach-Object { "<li>$_</li>" }
        "<details>
            <summary>View Dates ($($vm.RestorePointCount))</summary>
            <ul>
                $($restorePointItems -join "`n")
            </ul>
        </details>"
    } else {
        "No Restore Points"
    }

    "<tr>
        <td>$($vm.VMName)</td>
        <td>$($vm.LastBackup)</td>
        <td>$($restorePointDropdown)</td>
    </tr>"
}

# Build the complete HTML content
$htmlContent = @"
<!DOCTYPE html>
<html>
<head>
    <title>VM Backup Report</title>
    $css
</head>
<body>
    <h1>VM Backup Report</h1>
    <input type="text" id="searchInput" onkeyup="filterTable()" placeholder="Search for VMs or details...">
    <table id="vmBackupTable">
        <thead>
            <tr>
                <th>VM Name</th>
                <th>Last Backup</th>
                <th>Restore Points</th>
            </tr>
        </thead>
        <tbody>
            $($htmlRows -join "`n")
        </tbody>
    </table>
    $javascript
</body>
</html>
"@

# Save the HTML content to a file
$htmlContent | Out-File -FilePath $htmlReportPath -Encoding UTF8

# Notify user
Write-Output "VM Backup Report generated at: $htmlReportPath"

# Disconnect from Veeam Backup & Replication Server
Disconnect-VBRServer
