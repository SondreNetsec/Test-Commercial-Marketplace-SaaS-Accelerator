# --------------------------------------------
# Upgrade.ps1 - Updated to use Azure AD Authentication
# --------------------------------------------

# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License. See LICENSE file in the project root for license information.

#
# PowerShell script to deploy the resources - Customer portal, Publisher portal, and the Azure SQL Database
#

Param(  
   [string][Parameter(Mandatory)]$WebAppNamePrefix, # Prefix used for creating web applications
   [string][Parameter(Mandatory)]$ResourceGroupForDeployment # Name of the resource group to deploy the resources
)

# Define the message
$message = @"
The SaaS Accelerator is offered under the MIT License as open source software and is not supported by Microsoft.

If you need help with the accelerator or would like to report defects or feature requests use the Issues feature on the GitHub repository at https://aka.ms/SaaSAccelerator

Do you agree? (Y/N)
"@

# Display the message in yellow
Write-Host $message -ForegroundColor Yellow

# Prompt the user for input
$response = Read-Host

# Check the user's response
if ($response -ne 'Y' -and $response -ne 'y') {
    Write-Host "You did not agree. Exiting..." -ForegroundColor Red
    exit
}

# Proceed if the user agrees
Write-Host "Thank you for agreeing. Proceeding with the script..." -ForegroundColor Green

Function String-Between
{
	[CmdletBinding()]
	Param(
		[Parameter(Mandatory=$true)][String]$Source,
		[Parameter(Mandatory=$true)][String]$Start,
		[Parameter(Mandatory=$true)][String]$End
	)
	$sIndex = $Source.indexOf($Start) + $Start.length
	$eIndex = $Source.indexOf($End, $sIndex)
	return $Source.Substring($sIndex, $eIndex-$sIndex)
}

$ErrorActionPreference = "Stop"
$WebAppNameAdmin = "$WebAppNamePrefix-admin"    # Simplified string concatenation
$WebAppNamePortal = "$WebAppNamePrefix-portal"  # Simplified string concatenation
$KeyVault = "$WebAppNamePrefix-kv"              # Simplified string concatenation

#### THIS SECTION DEPLOYS CODE AND DATABASE CHANGES
Write-Host "#### Deploying new database ####" 

# Retrieve the ConnectionString from Azure Key Vault
$ConnectionString = az keyvault secret show `
	--vault-name $KeyVault `
	--name "DefaultConnection" `
	--query "value" `
	--output tsv

# **Change 1:** Remove extraction of User and Password since Azure AD authentication doesn't use SQL credentials
# **Change 2:** Remove User and Pass variables
# **Change 3:** Modify extraction to only get Server and Database from ConnectionString
# **Change 4:** Add retrieval of Access Token for Azure SQL Database

# Extract Server and Database from ConnectionString
$Server = String-Between -Source $ConnectionString -Start "Server=tcp:" -End "," # Adjusted to match connection string format
$Database = String-Between -Source $ConnectionString -Start "Database=" -End ";" 

# **Change 5:** Remove extraction of User and Password
# $User = String-Between -Source $ConnectionString -Start "User Id=" -End ";"  # Removed
# $Pass = String-Between -Source $ConnectionString -Start "Password=" -End ";"    # Removed

Write-Host "## Retrieved ConnectionString from KeyVault"

# Update the appsettings.Development.json with the new ConnectionString
Set-Content -Path "../src/AdminSite/appsettings.Development.json" -Value "{`"ConnectionStrings`": {`"DefaultConnection`":`"$ConnectionString`"}}"

# Generate the migration script using Entity Framework
dotnet-ef migrations script `
	--idempotent `
	--context SaaSKitContext `
	--project ../src/DataAccess/DataAccess.csproj `
	--startup-project ../src/AdminSite/AdminSite.csproj `
	--output script.sql
	
Write-Host "## Generated migration script"	

Write-Host "## !!!Attempting to upgrade database to migration compatibility.!!!"	

# Define the compatibility script
$compatibilityScript = @"
IF OBJECT_ID(N'[__EFMigrationsHistory]') IS NULL 
-- No __EFMigrations table means Database has not been upgraded to support EF Migrations
BEGIN
    CREATE TABLE [__EFMigrationsHistory] (
        [MigrationId] nvarchar(150) NOT NULL,
        [ProductVersion] nvarchar(32) NOT NULL,
        CONSTRAINT [PK___EFMigrationsHistory] PRIMARY KEY ([MigrationId])
    );

    IF (SELECT TOP 1 VersionNumber FROM DatabaseVersionHistory ORDER BY CreateBy DESC) = '2.10'
	    INSERT INTO [__EFMigrationsHistory] ([MigrationId], [ProductVersion]) 
	        VALUES (N'20221118045814_Baseline_v2', N'6.0.1');

    IF (SELECT TOP 1 VersionNumber FROM DatabaseVersionHistory ORDER BY CreateBy DESC) = '5.00'
	    INSERT INTO [__EFMigrationsHistory] ([MigrationId], [ProductVersion])  
	        VALUES (N'20221118045814_Baseline_v2', N'6.0.1'), (N'20221118203340_Baseline_v5', N'6.0.1');

    IF (SELECT TOP 1 VersionNumber FROM DatabaseVersionHistory ORDER BY CreateBy DESC) = '6.10'
	    INSERT INTO [__EFMigrationsHistory] ([MigrationId], [ProductVersion])  
	        VALUES (N'20221118045814_Baseline_v2', N'6.0.1'), (N'20221118203340_Baseline_v5', N'6.0.1'), (N'20221118211554_Baseline_v6', N'6.0.1');
END;
GO
"@

# **Change 6:** Remove -Username and -Password parameters
# **Change 7:** Use Azure AD Authentication by acquiring an Access Token and passing it via -AccessToken
# **Change 8:** Import Az module and authenticate if not already done

# Import the Az module if not already imported
Import-Module Az -ErrorAction Stop

# **Change 9:** Ensure the script is authenticated to Azure. If running in an automated environment, consider using a service principal or managed identity.
# For interactive sessions, Connect-AzAccount can be used. For non-interactive, use Connect-AzAccount with appropriate parameters or use a managed identity.
# Here, we'll assume an interactive session.

try {
    # Connect to Azure account (this will prompt for interactive login)
    Connect-AzAccount -ErrorAction Stop

    # Acquire the access token for Azure SQL Database
    $token = (Get-AzAccessToken -ResourceUrl "https://database.windows.net/").Token
}
catch {
    Write-Error "Failed to authenticate to Azure and acquire access token: $_"
    exit 1
}

# **Change 10:** Execute the compatibility script using the access token
try {
    Invoke-Sqlcmd `
        -Query $compatibilityScript `
        -ServerInstance $Server `
        -Database $Database `
        -AccessToken $token `
        -Authentication "ActiveDirectoryAccessToken" # Specify authentication method when using access token
    Write-Host "## Ran compatibility script against database"
}
catch {
    Write-Error "Failed to execute compatibility script: $_"
    exit 1
}

# **Change 11:** Execute the migration script using the access token
try {
    Invoke-Sqlcmd `
        -InputFile "script.sql" `
        -ServerInstance $Server `
        -Database $Database `
        -AccessToken $token `
        -Authentication "ActiveDirectoryAccessToken" # Specify authentication method when using access token
    Write-Host "## Ran migration against database"	
}
catch {
    Write-Error "Failed to execute migration script: $_"
    exit 1
}

# Remove temporary files
Remove-Item -Path "../src/AdminSite/appsettings.Development.json" -ErrorAction SilentlyContinue
Remove-Item -Path "script.sql" -ErrorAction SilentlyContinue
Write-Host "#### Database Deployment complete ####"	


Write-Host "#### Deploying new code ####" 

# Publish the Admin Site
dotnet publish ../src/AdminSite/AdminSite.csproj -v q -c release -o ../Publish/AdminSite/
Write-Host "## Admin Portal built" 

# Publish the Metered Trigger Job
dotnet publish ../src/MeteredTriggerJob/MeteredTriggerJob.csproj -v q -c release -o ../Publish/AdminSite/app_data/jobs/triggered/MeteredTriggerJob --runtime win-x64 --self-contained true 
Write-Host "## Metered Scheduler to Admin Portal Built"

# Publish the Customer Site
dotnet publish ../src/CustomerSite/CustomerSite.csproj -v q -c release -o ../Publish/CustomerSite
Write-Host "## Customer Portal Built" 

# Compress the published sites into ZIP files for deployment
Compress-Archive -Path "../Publish/CustomerSite/*" -DestinationPath "../Publish/CustomerSite.zip" -Force
Compress-Archive -Path "../Publish/AdminSite/*" -DestinationPath "../Publish/AdminSite.zip" -Force
Write-Host "## Code packages prepared." 

# Deploy code to Admin Portal using Azure CLI
Write-Host "## Deploying code to Admin Portal"
az webapp deploy `
	--resource-group $ResourceGroupForDeployment `
	--name $WebAppNameAdmin `
	--src-path "../Publish/AdminSite.zip" `
	--type zip
Write-Host "## Deployed code to Admin Portal"

# Deploy code to Customer Portal using Azure CLI
Write-Host "## Deploying code to Customer Portal"
az webapp deploy `
	--resource-group $ResourceGroupForDeployment `
	--name $WebAppNamePortal `
	--src-path "../Publish/CustomerSite.zip"  `
	--type zip
Write-Host "## Deployed code to Customer Portal"

# Clean up the Publish directory
Remove-Item -Path "../Publish" -Recurse -Force
Write-Host "#### Code deployment complete ####" 
Write-Host ""
Write-Host "#### Warning!!! ####"
Write-Host "#### If the upgrade is to >=7.5.0, MeterScheduler feature is pre-enabled and changed to DB config instead of the App Service configuration. Please update the IsMeteredEnabled value accordingly in the Admin portal -> Settings page. ####"
Write-Host "#### "

# --------------------------------------------
# End of Upgrade.ps1
# --------------------------------------------
