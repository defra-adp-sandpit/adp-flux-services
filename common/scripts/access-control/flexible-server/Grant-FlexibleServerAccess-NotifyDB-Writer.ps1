<#
.SYNOPSIS
Grant access to postgres flexible server for service (tier-3) managed identity.

.DESCRIPTION
Grant access to postgres flexible server for service (tier-3) managed identity.

.EXAMPLE
.\Grant-FlexibleServerAccess.ps1 
#>

Set-StrictMode -Version 3.0

[string]$PostgresHost = $env:POSTGRES_HOST 
[string]$PostgresDatabase = $env:POSTGRES_DATABASE
[string]$PlatformMIName = $env:PLATFORM_MI_NAME 
[string]$PlatformMIClientId = $env:AZURE_CLIENT_ID
[string]$PlatformMITenantId = $env:AZURE_TENANT_ID
[string]$PlatformMISubscriptionId = $env:PLATFORM_MI_SUBSCRIPTION_ID 
[string]$SubscriptionName = $env:SUBSCRIPTION_NAME
[string]$WorkingDirectory = $PWD
[string]$PostgresReaderAdGroup = $env:PG_READER_AD_GROUP
[string]$PostgresWriterAdGroup = $env:PG_WRITER_AD_GROUP

[string]$functionName = $MyInvocation.MyCommand
[DateTime]$startTime = [DateTime]::UtcNow
[int]$exitCode = -1
[bool]$setHostExitCode = (Test-Path -Path ENV:TF_BUILD) -and ($ENV:TF_BUILD -eq "true")
[bool]$enableDebug = (Test-Path -Path ENV:SYSTEM_DEBUG) -and ($ENV:SYSTEM_DEBUG -eq "true")

Set-Variable -Name ErrorActionPreference -Value Continue -scope global
Set-Variable -Name VerbosePreference -Value Continue -Scope global

if ($enableDebug) {
    Set-Variable -Name DebugPreference -Value Continue -Scope global
    Set-Variable -Name InformationPreference -Value Continue -Scope global
}

Write-Host "${functionName} started at $($startTime.ToString('u'))"
Write-Debug "${functionName}:PostgresHost:$PostgresHost"
Write-Debug "${functionName}:PostgresDatabase:$PostgresDatabase"
Write-Debug "${functionName}:PlatformMIName:$PlatformMIName"
Write-Debug "${functionName}:SubscriptionName=$SubscriptionName"
Write-Debug "${functionName}:WorkingDirectory=$WorkingDirectory"
Write-Debug "${functionName}:PostgresReaderAdGroup=$PostgresReaderAdGroup"
Write-Debug "${functionName}:PostgresWriterAdGroup=$PostgresWriterAdGroup"

[System.IO.DirectoryInfo]$scriptDir = $PSCommandPath | Split-Path -Parent
Write-Debug "${functionName}:scriptDir.FullName:$($scriptDir.FullName)"

function Get-SQLScriptToCreatePrincipal {
    [System.Text.StringBuilder]$builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append(' DO $$ ')
    [void]$builder.Append(' BEGIN ')
    [void]$builder.Append("     IF NOT EXISTS (SELECT 1 FROM pgaadauth_list_principals(false) WHERE rolname='$PostgresWriterAdGroup') THEN ")
    [void]$builder.Append("         RAISE NOTICE 'CREATING PRINCIPAL FOR MANAGED IDENTITY:$PostgresWriterAdGroup';")
    [void]$builder.Append("         PERFORM pgaadauth_create_principal('$PostgresWriterAdGroup', false, false); ");
    [void]$builder.Append("         RAISE NOTICE 'PRINCIPAL FOR MANAGED IDENTITY CREATED:$PostgresWriterAdGroup';")
    [void]$builder.Append('     ELSE ')
    [void]$builder.Append("         RAISE NOTICE 'PRINCIPAL FOR MANAGED IDENTITY ALREADY EXISTS:$PostgresWriterAdGroup';")
    [void]$builder.Append('     END IF; ')
    [void]$builder.Append("     IF NOT EXISTS (SELECT 1 FROM pgaadauth_list_principals(false) WHERE rolname='$PostgresReaderAdGroup') THEN ")
    [void]$builder.Append("         RAISE NOTICE 'CREATING PRINCIPAL FOR MANAGED IDENTITY:$PostgresReaderAdGroup';")
    [void]$builder.Append("         PERFORM pgaadauth_create_principal('$PostgresReaderAdGroup', false, false); ");
    [void]$builder.Append("         RAISE NOTICE 'PRINCIPAL FOR MANAGED IDENTITY CREATED:$PostgresReaderAdGroup';")
    [void]$builder.Append('     ELSE ')
    [void]$builder.Append("         RAISE NOTICE 'PRINCIPAL FOR MANAGED IDENTITY ALREADY EXISTS:$PostgresReaderAdGroup';")
    [void]$builder.Append('     END IF; ')
    [void]$builder.Append("     EXECUTE ( 'GRANT CONNECT ON DATABASE `"$PostgresDatabase`" TO `"$PostgresWriterAdGroup`"' );")
    [void]$builder.Append("     EXECUTE ( 'GRANT CONNECT ON DATABASE `"$PostgresDatabase`" TO `"$PostgresReaderAdGroup`"' );")
    [void]$builder.Append("     RAISE NOTICE 'GRANTED CONNECT TO DATABASE';")
    [void]$builder.Append(" EXCEPTION ")
    [void]$builder.Append("     WHEN OTHERS THEN  ")
    [void]$builder.Append("         RAISE EXCEPTION 'ERROR DURING PRINCIPAL CREATION/GRANT CONNECT: %', SQLERRM; ")
    [void]$builder.Append(' END $$' )
    return $builder.ToString()
}

function Get-SQLScriptToGrantAllPermissions {
    [System.Text.StringBuilder]$builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append("GRANT ALL ON SCHEMA public TO `"$PostgresWriterAdGroup`";")
    [void]$builder.Append("GRANT USAGE ON SCHEMA public TO `"$PostgresReaderAdGroup`";")
    [void]$builder.Append("GRANT ALL ON ALL TABLES IN SCHEMA public TO `"$PostgresWriterAdGroup`";")
    [void]$builder.Append("GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO `"$PostgresWriterAdGroup`";")
    [void]$builder.Append("GRANT ALL ON ALL FUNCTIONS IN SCHEMA public TO `"$PostgresWriterAdGroup`";")
    [void]$builder.Append("GRANT ALL ON ALL PROCEDURES IN SCHEMA public TO `"$PostgresWriterAdGroup`";")
    [void]$builder.Append("ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO `"$PostgresWriterAdGroup`";")
    [void]$builder.Append("ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO `"$PostgresWriterAdGroup`";")
    return $builder.ToString()
}

[string]$tempFolder=[System.IO.Path]::GetTempPath()
[System.IO.FileInfo]$createPrincipalTempFile = $tempFolder + $(New-Guid).ToString() + ".sql";
[System.IO.FileInfo]$assignAllPermissionsTempFile = $tempFolder + $(New-Guid).ToString() + ".sql";

try {
    [System.IO.DirectoryInfo]$moduleDir = Join-Path -Path $WorkingDirectory -ChildPath "common/scripts/modules/psql"
    Write-Debug "${functionName}:moduleDir.FullName=$($moduleDir.FullName)"
    Import-Module $moduleDir.FullName -Force

    Write-Host "Connecting to Azure..."
    $azureContext = (Connect-AzAccount -Identity -AccountId $PlatformMIClientId -Tenant $PlatformMITenantId -Subscription $PlatformMISubscriptionId).context
    $null = Set-AzContext -Subscription $SubscriptionName -DefaultProfile $azureContext
    Write-Host "Connected to Azure and set context to '$SubscriptionName'"

    Write-Host "Acquiring Access Token..."
    $accessToken = Get-AzAccessToken -ResourceUrl "https://ossrdbms-aad.database.windows.net"
    $ENV:PGPASSWORD = $accessToken.Token
    Write-Host "Access Token Acquired"

    [string]$command = Get-SQLScriptToCreatePrincipal
    Write-Debug "${functionName}:command=$command"
    
    [string]$content = Set-Content -Path $createPrincipalTempFile.FullName -Value $command -PassThru -Force
    Write-Debug "${functionName}:$($createPrincipalTempFile.FullName)=$content"

    Write-Host "Creating Principal in ${PostgresHost} and Granting connect permissions"
    $null = Invoke-PSQLScript -PostgresHost $PostgresHost -PostgresDatabase "postgres" -PostgresUsername $PlatformMIName -Path $createPrincipalTempFile.FullName
    Write-Host "Granted Access to ${PostgresHost}"

    [string]$command = Get-SQLScriptToGrantAllPermissions
    Write-Debug "${functionName}:command=$command"
    
    [string]$content = Set-Content -Path $assignAllPermissionsTempFile.FullName -Value $command -PassThru -Force
    Write-Debug "${functionName}:$($assignAllPermissionsTempFile.FullName)=$content"

    Write-Host "Granting permissions to ${PostgresWriterAdGroup}"
    $null = Invoke-PSQLScript -PostgresHost $PostgresHost -PostgresDatabase $PostgresDatabase -PostgresUsername $PlatformMIName -Path $assignAllPermissionsTempFile.FullName
    Write-Host "Granted Access to ${PostgresWriterAdGroup}"

    # Successful exit
    $exitCode = 0
} 
catch {
    $exitCode = -2
    Write-Error $_.Exception.ToString()
    throw $_.Exception
}
finally {
    Remove-Item -Path $createPrincipalTempFile.FullName -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $assignAllPermissionsTempFile.FullName -Force -ErrorAction SilentlyContinue

    [DateTime]$endTime = [DateTime]::UtcNow
    [Timespan]$duration = $endTime.Subtract($startTime)

    Write-Host "${functionName} finished at $($endTime.ToString('u')) (duration $($duration -f 'g')) with exit code $exitCode"

    if ($setHostExitCode) {
        Write-Debug "${functionName}:Setting host exit code"
        $host.SetShouldExit($exitCode)
    }
    exit $exitCode
}