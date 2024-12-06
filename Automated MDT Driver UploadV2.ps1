
# Function to check if the script is running as Administrator
param (
    [switch]$Elevated
)

function Test-Admin {
    $currentUser = New-Object Security.Principal.WindowsPrincipal $([Security.Principal.WindowsIdentity]::GetCurrent())
    $currentUser.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

if ((Test-Admin) -eq $false) {
    if ($Elevated) {
        Write-Host "Failed to elevate permissions. Aborting." -ForegroundColor Red
    }
    else {
        Write-Host "Elevating permissions..."
        Start-Process powershell.exe -Verb RunAs -ArgumentList ("-NoProfile", "-NoExit", "-File", "`"$($myinvocation.MyCommand.Definition)`"", "-Elevated")
    }
    exit
}

Write-Host "Running with full privileges"

#Start the timer for tracking total execution time
$starttime = Get-Date



$module = "C:\Program Files\Microsoft Deployment Toolkit\Bin\MicrosoftDeploymentToolkit.psd1"
 $deploymentshare = Read-Host -Prompt "Enter full deploymentshare path: (ex. \\cicorpwd01\G$\Winbase10)"
 Import-Module  $module 

# Function to find the next available PSDrive name in the DSxxx format
function Get-NextPSDriveName {
    # Get all existing PSDrives with names matching the pattern DSxxx
    $existingDrives = Get-PSDrive | Where-Object { $_.Name -match "^DS\d{3}$" }

    if ($existingDrives) {
        # Find the highest number used in existing PSDrive names
        $maxNum = $existingDrives |
            ForEach-Object {
                if ($_.Name -match "^DS(\d{3})$") { 
                    [int]$matches[1]
                } else {
                    0  # In case of unexpected names (but should not happen in this case)
                }
            } | Sort-Object -Descending | Select-Object -First 1

        # Increment the highest number found and format as DSxxx
        return "DS" + ($maxNum + 1).ToString("D3")
    } else {
        # If no "DSxxx" PSDrive exists, start with DS001
        return "DS001"
    }
}

# Check if there is an existing PSDrive mapped to the deployment share root path
$existingPSDrive = Get-PSDrive | Where-Object { $_.Root -eq $deploymentshare -and $_.Provider.Name -eq "MDTProvider" }

# Determine the PSDrive name
$psDriveName = if ($existingPSDrive) {
    $existingPSDrive.Name
} else {
    Get-NextPSDriveName
}

# If a PSDrive is found, remove it using its name
if ($existingPSDrive) {
    Remove-PSDrive -Name $existingPSDrive.Name -Force
    Write-Host "The existing PSDrive '$($existingPSDrive.Name)' mapped to '$deploymentshare' has been removed."
}

# Create a new PSDrive with the determined name (sequential if necessary)
New-PSDrive -Name $psDriveName -PSProvider MDTProvider -Root $deploymentshare
Write-Host "The PSDrive '$psDriveName' has been mapped to your Deployment Share."
Write-Host ""

# Get the hostname and serial number of the device
#$global:hostname = $env:COMPUTERNAME
#$global:serialNumber = (Get-WmiObject -Class Win32_BIOS).SerialNumber

$global:userName = "$env:USERNAME"
$global:timeStamp = get-date -format yyyy-MM-dd_HH-mm-ss

# Define the log file (Transcript will handle logging)
# Set the log directory and check if it exists
$global:logDir = "\\path\to \log\Folder"
$global:logFilePath = Join-Path -Path $global:logDir -ChildPath "msuImport_${global:userName}_$global:timeStamp.log"

Start-Transcript -Path $global:logFile -Append

Write-Host ""

try {
    # Prompt the user to specify how many drivers to upload
    $numDrivers = [int](Read-Host "How many drivers do you want to upload?")

    # Initialize an empty array to store the driver paths and folders
    $drivers = @()

    # Loop to collect the source paths and folder names from the user
    for ($i = 1; $i -le $numDrivers; $i++) {
        $sourcePath = Read-Host "Enter the source path for driver $i"
		Write-Host ""
        $folder = Read-Host "Enter the device Model name for driver $i (e.g., 201234567 or Latitude 7540)"
		Write-Host ""

        # Validate that the source path exists
        if (-not (Test-Path $sourcePath)) {
            throw "Source path '$sourcePath' does not exist. Please check the path and try again."
        }

        # Add the source path and folder to the array
        $drivers += @{ SourcePath = $sourcePath; MDTFolder = $folder }
    }

    # Loop through each driver set and process them
    foreach ($driver in $drivers) {
        $folder = $driver.MDTFolder
        $sourcePath = $driver.SourcePath
        
        # Check if the folder already exists in the MDT Deployment Share
        $mdtFolderPath = "${psDriveName}:\Out-of-Box Drivers\$folder"
        if (Test-Path $mdtFolderPath) {
            # Prompt user for confirmation to continue
            $response = Read-Host "The folder '$mdtFolderPath' already exists. Do you want to continue importing drivers into this folder? (Yes/No)"
            
            if ($response -ne "Yes") {
                Write-Host "Skipping upload for '$sourcePath'." -ForegroundColor Yellow
                continue
            }
        } else {
            # If the folder does not exist, create it
            Write-Host "The folder '$mdtFolderPath' does not exist. Creating the folder..." -ForegroundColor Green
            try {
                New-Item -Path $mdtFolderPath -ItemType Directory -Force
                Write-Host "Created folder '$mdtFolderPath'." -ForegroundColor Green
            } catch {
                throw "Failed to create folder '$mdtFolderPath'. Error: $_"
            }
        }

        # Import drivers into the specified MDT folder
        try {
            Write-Host "Importing drivers from '$sourcePath' into '$mdtFolderPath'..." -ForegroundColor Cyan
            Import-MDTDriver -Path $mdtFolderPath -SourcePath $sourcePath -ImportDuplicates -Verbose
            Write-Host "Drivers from '$sourcePath' successfully imported into '$mdtFolderPath'." -ForegroundColor Green
        } catch {
            Write-Host "Error importing drivers from '$sourcePath' into '$mdtFolderPath'. Error: $_" -ForegroundColor Red
        }
    }
} catch {
    Write-Host "An error occurred: $_" -ForegroundColor Red
} finally {
	# End of script - Calculate total plan
	$endtime = Get-Date
	$Totalduration = $endtime - $starttime
	Write-Host "Script completed uploading the following drivers: $drivers in $($Totalduration.TotalMinutes) minutes."  
	
    Stop-Transcript
    Write-Host "Process completed. Check the log file for details: $logFile" -ForegroundColor Green
}
