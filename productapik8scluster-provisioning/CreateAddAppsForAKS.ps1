param(
	[Parameter(Mandatory=$true)]
	[string] $TenantId,

    [Parameter(Mandatory=$true)]
    [string] $appName,
	
	[Parameter(Mandatory=$true)]
	[string] $AadAdmin,
	
	[Parameter(Mandatory=$true)]
	[securestring] $AadPassword

	#[Parameter(Mandatory=$true)]
	#[string[]] $ClientPermissionNames,

	#[bool] $IsDevelopment = $true
)

$ErrorActionPreference = 'Stop'

function CreateAppRole([string] $Name, [string] $Description, [Guid] $Id)
{
    $appRole = New-Object Microsoft.Open.AzureAD.Model.AppRole
    $appRole.AllowedMemberTypes = New-Object System.Collections.Generic.List[string]
    $appRole.AllowedMemberTypes.Add("User");
    $appRole.AllowedMemberTypes.Add("Application");
    $appRole.DisplayName = $Name
    $appRole.Id = $Id
    $appRole.IsEnabled = $true
    $appRole.Description = $Description
    $appRole.Value = $Name;

    return $appRole
}

function SafeAddGroupToRole($servicePrincipalId, $groupId, $appRoleId) {
	Write-Host "Searching for an already existing assignment in $servicePrincipalId for Role $appRoleId and Group $groupId"

	$assignment = Get-AzureADGroupAppRoleAssignment -ObjectId $groupId `
		-All $true | Where-Object { ($_.ResourceId -eq $servicePrincipalId) -and ($_.Id -eq $appRoleId)}

	if ($assignment) {
		Write-Host "Group $groupId already assigned"
        return
	}

    $assignment = New-AzureADGroupAppRoleAssignment -ObjectId $groupId -PrincipalId $groupId -ResourceId $servicePrincipalId -Id $appRoleId

    Write-Host "Group assigned to application."
}

function GetRequiredPermissions([string[]] $PermissionNames, [string] $AppId) {
	Write-Host "Retrieving Permissions for App $AppId"

	$targetSp = Get-AzureADServicePrincipal -All:$true | where AppId -eq $AppId

	if (!$targetSp) {
		throw "Service principal not found for app $AppId"
	}

	$Permissions = $targetSp.Oauth2Permissions | where value -In $PermissionNames

	Write-Host "Permissions found:"
    Write-Host ($Permissions | select Id, AdminConsentDisplayName, Value)

	$req = New-Object -TypeName "Microsoft.Open.AzureAD.Model.RequiredResourceAccess"
    $req.ResourceAccess = New-Object -TypeName "System.Collections.Generic.List[Microsoft.Open.AzureAD.Model.ResourceAccess]"

	foreach ($permission in $Permissions) {
        $resource = New-Object -TypeName "Microsoft.Open.AzureAD.Model.ResourceAccess" -ArgumentList $permission.Id, "Scope"
        $req.ResourceAccess.Add($resource)
    }

	$req.ResourceAppId = $AppId

    return $req
}

function ConfigureAdApplicationForClient([string] $adWebAppName, [Guid] $AppId, [string[]] $PermissionNames)
{
	$adClientAppDisplayName = $adWebAppName + 'client'

	$uri = "http://$defaultDomain/$adClientAppDisplayName"

	# Create native AD application

	Write-Host "Looking for existing application for client..."
	$adClientApp = Get-AzureADApplication -Filter "DisplayName eq '$adClientAppDisplayName'"

	if ($adClientApp) {
		Write-Host "Application for client already exists. Updating..."
		Set-AzureADApplication -ObjectId $adClientApp.ObjectId -PublicClient $true -ReplyUrls "urn:ietf:wg:oauth:2.0:oob"
	}
	else {
		Write-Host "Creating new application for client..."
		$newApp = New-AzureADApplication -DisplayName $adClientAppDisplayName -PublicClient $true -ReplyUrls "urn:ietf:wg:oauth:2.0:oob"
	}

	$adClientApp = Get-AzureADApplication -Filter "DisplayName eq '$adClientAppDisplayName'"
	$adClientAppId = $adClientApp.AppID

	# Set required resource access

	$req = GetRequiredPermissions -AppId $AppId -PermissionNames $ClientPermissionNames
	Set-AzureADApplication -ObjectId $adClientApp.ObjectId -RequiredResourceAccess $req

	return $adClientAppId
}

function MergeAppRoles([System.Collections.Generic.List[Microsoft.Open.AzureAD.Model.AppRole]] $source, 
    [System.Collections.Generic.List[Microsoft.Open.AzureAD.Model.AppRole]] $target) 
{
	foreach ($role in $source) {
		$exists = $target | Where-Object { $_.DisplayName -eq  $role.DisplayName };
		if (!$exists) {
			$target.Add($role)
		}
	}
}

function ConfigureAdApplicationForWebApp([string] $appName, [string] $DefaultDomain)
{
	$appUrl = "http://" + $appName 

	#$adAppDisplayName = $aksAppName

	#$uri = "http://$defaultDomain/$adAppDisplayName"

	# Set app roles
	#$userRole = CreateAppRole -Name "HPUser" -Description "Users who can access the API in almost read-only mode" -Id ([Guid]"5004FEFC-2E7C-4E40-976F-1471D4D4F08E")
	#$adminRole = CreateAppRole -Name "HPAdmin" -Description "Users who have full API access" -Id ([Guid]"83C44DB1-62CC-405D-9697-B819DA0175A3")

	#$appRoles = New-Object System.Collections.Generic.List[Microsoft.Open.AzureAD.Model.AppRole]

	#$appRoles.Add($userRole)
	#$appRoles.Add($adminRole)
    Write-Host "Looking for existing application for web app..."
	$app = Get-AzureADApplication -Filter "DisplayName eq '$appName'"

	if ($app) {
		Write-Host "Application for web app already exists."

		#MergeAppRoles -source $app.AppRoles -target $appRoles

		#Set-AzureADApplication -ObjectId $app.ObjectId -IdentifierUris $uri -ReplyUrls $replyUrls -Oauth2AllowImplicitFlow $true -Homepage $apiWebAppUrl -AppRoles $appRoles -GroupMembershipClaims "All"
	}
	else {
		Write-Host "Creating new application for web app..."
		$newApp = New-AzureADApplication -DisplayName $appName -IdentifierUris $appUrl -Homepage $appUrl -Oauth2AllowImplicitFlow $true -GroupMembershipClaims "All"
	}

	$app = Get-AzureADApplication -Filter "DisplayName eq '$appName'"

	Write-Host "Looking for existing service principal for web app..."
	$sp = Get-AzureADServicePrincipal -All $true | where AppId -eq $app.AppID

	$appId = $app.AppID

	if ($sp){
		Write-Host "Service principal for web app already exists. Updating..."
		Set-AzureADServicePrincipal -ObjectId $sp.ObjectId -AppRoleAssignmentRequired $true
	}
	else {
		Write-Host "Creating new service principal for web app..."
		$sp = New-AzureADServicePrincipal -AppId $appId -AppRoleAssignmentRequired $true
	}

	Write-Host "Successfully set application and service principal for web app."

	#if ($HpUsersGroupId) {
	#	Write-Host "HpUserGroupId provided: adding it to the ServicePrincipal"

	#	$dummy = SafeAddGroupToRole -servicePrincipalId $sp.ObjectId `
	#		-groupId $HpUsersGroupId `
	#		-appRoleId $userRole.Id
	#}

	#if ($HpAdminsGroupId) {
	#	Write-Host "HpAdminsGroupId provided: adding it to the ServicePrincipal"

	#	$dummy = SafeAddGroupToRole -servicePrincipalId $sp.ObjectId `
	#		-groupId $HpAdminsGroupId `
	#		-appRoleId $adminRole.Id
	#}

	return $app
}

if (!(Get-Module AzureAD)) {
	Write-Host "Installing/updating AzureAD module..."
	Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser
	Install-Module AzureAD -Scope CurrentUser -Force
}

Write-Host "Connecting to Azure AD..."
$Credentials = New-Object -TypeName "System.Management.Automation.PSCredential" -ArgumentList $AadAdmin, $AadPassword
Connect-AzureAD -TenantId $TenantId -Credential $Credentials

$tenantDetail = Get-AzureADTenantDetail
$defaultDomain = ($tenantDetail.VerifiedDomains | where _Default).Name

$app = ConfigureAdApplicationForWebApp -appName $appName  -DefaultDomain $defaultDomain
$webAppId = $app.AppID
$webAppIdUri = $app.IdentifierUris
#$clientAppId = ConfigureAdApplicationForClient -adWebAppName $WebAppName -AppId $webAppId

Write-Host
Write-Host "Web app AD Client ID : $webAppId"
Write-Host "Web app AD Client ID URI : $webAppIdUri"
Write-Host "Client AD Client ID : $clientAppId"
Write-Host

return $app
