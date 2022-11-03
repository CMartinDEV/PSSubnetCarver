# Modified function found here: https://stackoverflow.com/questions/8365537/checking-for-a-range-in-powershell
function Test-IPAddressInRange {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory, Position = 0)]
        [string] $IPAddress,
        [Parameter(Mandatory, Position = 1)]
        [string] $FromAddress,
        [Parameter(Mandatory, Position = 2)]
        [string] $ToAddress
        )
    
        $ip = [System.Net.IPAddress]::Parse($IPAddress).GetAddressBytes()
        [array]::Reverse($ip)
        $ip = [System.BitConverter]::ToUInt32($ip, 0)
    
        $from = [System.Net.IPAddress]::Parse($FromAddress).GetAddressBytes()
        [array]::Reverse($from)
        $from = [System.BitConverter]::ToUInt32($from, 0)
    
        $to = [System.Net.IPAddress]::Parse($ToAddress).GetAddressBytes()
        [array]::Reverse($to)
        $to = [System.BitConverter]::ToUInt32($to, 0)
    
        $from -le $ip -and $ip -le $to
}

<#
.SYNOPSIS
 Import a PSSubnetCarver context from a file on disk, or from Azure blob storage.

.DESCRIPTION
 Import a PSSubnetCarver context from a .json file either stored on disk, or stored in Azure blob storage. If in Azure blob storage, it will be downloaded via the REST API using a SAS token.

.PARAMETER Path
 The path of the .json file that contains the stored information about the context.

.PARAMETER Json
 The JSON of the object.

.PARAMETER StorageAccountName
 The name of the Azure storage account.

.PARAMETER ContainerName
 The name of the container in the Azure storage account.

.PARAMETER SASToken
 The SAS token to use when making the REST request.

.PARAMETER ContextName
 The name of the context to identify which .json file to download from Azure.
#>
function Import-SCContext {
    [CmdletBinding(DefaultParameterSetName = "FromFile")]
    Param(
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = "FromFile")]
        [ValidateScript( {
                if (-not (Test-Path -Path $_ -PathType Leaf)) {
                    throw "File not found at $_"
                }

                return $true
            })]
        [string]$Path,

        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = "FromJson")]
        [string]$Json,

        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = "FromStorageBlob")]
        [string]$StorageAccountName,

        [Parameter(Mandatory = $true, Position = 1, ParameterSetName = "FromStorageBlob")]
        [string]$ContainerName,

        [Parameter(Mandatory = $true, Position = 2, ParameterSetName = "FromStorageBlob")]
        [string]$SASToken,

        [Parameter(Mandatory = $false, Position = 3, ParameterSetName = "FromStorageBlob")]
        [string]$ContextName = "default",

        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = "FromAzureVirtualNetwork")]
        [Guid]$SubscriptionId,
        [Parameter(Mandatory = $true, Position = 1, ParameterSetName = "FromAzureVirtualNetwork")]
        [string]$ResourceGroupName,
        [Parameter(Mandatory = $true, Position = 2, ParameterSetName = "FromAzureVirtualNetwork")]
        [string]$VirtualNetworkName,
        [Parameter(Mandatory = $true, Position = 3, ParameterSetName = "FromAzureVirtualNetwork")]
        [string]$BearerToken
    )

    if ($PSCmdlet.ParameterSetName -eq "FromFile") {
        $model = Get-Content -Path $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    elseif ($PSCmdlet.ParameterSetName -eq "FromJson") {
        $model = $Json | ConvertFrom-Json
    }
    elseif ($PSCmdlet.ParameterSetName -eq "FromStorageBlob") {

        $fileName = "$($ContextName.ToLower()).json"

        $filePath = Join-Path -Path $env:TEMP -ChildPath $fileName -ErrorAction Stop

        $blobDownloadParams = @{
            URI         = "https://$($StorageAccountName).blob.core.windows.net/$($ContainerName)/$($fileName)?$($SASToken.TrimStart('?'))"
            Method      = "GET"
            Headers     = @{
                'x-ms-blob-type' = "BlockBlob"
                'x-ms-meta-m1'   = 'v1'
                'x-ms-meta-m2'   = 'v2'
            }
            OutFile     = $filePath
            ErrorAction = 'Stop'
        }

        $null = Invoke-RestMethod @blobDownloadParams

        try {
            $model = Get-Content -Path $filePath | ConvertFrom-Json -ErrorAction Stop
        }
        finally {
            Remove-Item -LiteralPath $filePath -Force -Confirm:$false -ErrorAction SilentlyContinue
        }

    }
    elseif ($PSCmdlet.ParameterSetName -eq "FromAzureVirtualNetwork") {
        $uri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Network/virtualNetworks/$($VirtualNetworkName)?api-version=2022-05-01"

        $vnet = Invoke-RestMethod -Uri $uri -Method Get -Headers @{ Authorization = "bearer $BearerToken" } -ErrorAction Stop
    
        $contextName = $vnet.name
    
        $subnets = [System.Collections.ArrayList]$vnet.properties.subnets | Select-Object -Property 'Name',@{ Name = 'Range'; Expression = { [qIPAM.Models.IPAddressRange]$_.properties.addressPrefix } }
    
        $prefixes = [qIPAM.Models.IPAddressRange[]]$vnet.properties.addressSpace.addressPrefixes
    
        $prefixCount = $prefixes | Measure-Object | Select-Object -ExpandProperty Count
    
        foreach ($prefix in $prefixes) {
            
            $ctxName = if ($prefixCount -gt 1) {
                "$($contextName)_$($prefixes.IndexOf($prefix) + 1)"
            }
            else {
                $contextName
            }
    
            try {
                Set-SCContext -Name $ctxName -RootAddressSpace $prefix -ErrorAction Stop    
            }
            catch {
                Write-Error -Message "$_" -ErrorAction Continue
                continue
            }
    
            [System.Collections.ArrayList] $claimedSubnets = @()
    
            $subnets | ForEach-Object -Process { 
                try {
    
                    if ((Test-IPAddressInRange -ipAddress $_.Range.FirstUsableIPAddress -fromAddress $prefix.FirstUsableIPAddress -toAddress $prefix.LastUsableIPAddress) -and
                        (Test-IPAddressInRange -ipAddress $_.Range.LastUsableIPAddress -fromAddress $prefix.FirstUsableIPAddress -toAddress $prefix.LastUsableIPAddress)) {
                            $null = Get-SCSubnet -ContextName $ctxName -ReserveIPAddress $_.Range -ErrorAction Stop
                            $null = $claimedSubnets.Add($_.Range)
                    }
                }
                catch {
                    return
                }
             }
    
             $subnets = $subnets | Where-Object -Property Range -NotIn $claimedSubnets
        }

        # Adding return here because this one doesn't fit the pattern, and we don't want to hit the Set-SCContext at the end
        return
    }
    else {
        Write-Error -Message "Parameter set $($PSCmdlet.ParameterSetName) has not been properly implemented." -ErrorAction Stop
    }

    Set-SCContext -Name $model.Name -RootAddressSpace $model.RootIPAddressRange -ConsumedIPRanges $model.ConsumedRanges
}



<#
.SYNOPSIS
 Export a PSSubnetCarver context to disk, or to Azure blob storage.

.DESCRIPTION
 Export a PSSubnetCarver context to a .json file, and either store it on the local disk, or in Azure blob storage. If in Azure blob storage, it will be uploaded via the REST API using a SAS token.

.PARAMETER Path
 The path of the .json file that will contain the stored information about the context.

.PARAMETER StorageAccountName
 The name of the Azure storage account.

.PARAMETER ContainerName
 The name of the container in the Azure storage account.

.PARAMETER SASToken
 The SAS token to use when making the REST request.

.PARAMETER ContextName
 The name of the context to export.

#>
function Export-SCContext {
    [CmdletBinding(DefaultParameterSetName = "ToFile")]
    Param(
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = "ToFile")]
        [string]$Path,

        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = "ToAzure")]
        [string]$StorageAccountName,

        [Parameter(Mandatory = $true, Position = 1, ParameterSetName = "ToAzure")]
        [string]$ContainerName,

        [Parameter(Mandatory = $true, Position = 2, ParameterSetName = "ToAzure")]
        [string]$SASToken,

        [Parameter(Mandatory = $false, Position = 1, ParameterSetName = "ToFile")]
        [Parameter(Mandatory = $false, Position = 3, ParameterSetName = "ToAzure")]
        [string]$ContextName = "default",

        [Parameter(ParameterSetName = "ToFile")]
        [switch]$Force
    )

    $model = Get-SCContext -Name $ContextName -ErrorAction Stop

    $serialModel = [PSCustomObject]@{Name = $model.Name; RootIPAddressRange = $model.RootIPAddressRange.ToString(); ConsumedRanges = [System.Collections.ArrayList]@() }

    $model.ConsumedRanges | ForEach-Object -Process { $null = $serialModel.ConsumedRanges.Add($_.ToString()) }

    $json = $serialModel | ConvertTo-Json

    if ($PSCmdlet.ParameterSetName -eq "ToFile") {
        $json | Out-File -FilePath $Path -Force:$Force
    }
    elseif ($PSCmdlet.ParameterSetName -eq "ToAzure") {
        $fileName = "$($ContextName.ToLower()).json"

        $filePath = Join-Path -Path $env:TEMP -ChildPath $fileName -ErrorAction Stop

        $json | Out-File -FilePath $filePath -Force -ErrorAction Stop

        try {
            $blobUploadParams = @{
                URI         = "https://$($StorageAccountName).blob.core.windows.net/$($ContainerName)/$($fileName)?$($SASToken.TrimStart('?'))"
                Method      = "PUT"
                Headers     = @{
                    'x-ms-blob-type'                = "BlockBlob"
                    'x-ms-blob-content-disposition' = "attachment; filename=`"$($fileName)`""
                    'x-ms-meta-m1'                  = 'v1'
                    'x-ms-meta-m2'                  = 'v2'
                }
                InFile      = $filePath
                ErrorAction = 'Stop'
            }

            $null = Invoke-RestMethod @blobUploadParams
        }
        finally {
            Remove-Item -LiteralPath $filePath -Force -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
    else {
        Write-Error -Message "Parameter set $($PSCmdlet.ParameterSetName) has not been properly implemented."
    }
}

<#
.SYNOPSIS
 Rename an in-memory context.

.DESCRIPTION
 Rename an in-memory context, without modifying it's contents.

.PARAMETER OldContextName
 The name of the context as it is in memory as the command is run. Case insensitive.

.PARAMETER NewContextName
 The new name of the context. Case insensitive.
#>
function Rename-SCContext {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$OldContextName,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$NewContextName
    )

    if ([qIPAM.Extensions.QIPSubnetCarverContext]::Instances.ContainsKey($OldContextName)) {
        $context = Get-SCContext -Name $OldContextName -ErrorAction Stop

        Set-SCContext -Name $NewContextName -RootAddressSpace $context.RootIPAddressRange -ConsumedIPRanges $context.ConsumedRanges -ErrorAction Stop

        $null = [qIPAM.Extensions.QIPSubnetCarverContext]::Instances.Remove($OldContextName)
    }
    else {
        Write-Error -Message "No context stored with name $OldContextName"
    }
}

function Test-ContextConfigured {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    return [qIPAM.Extensions.QIPSubnetCarverContext]::Instances.ContainsKey($Name)

}

<#
.SYNOPSIS
 Clear the named context of it's stored networks, without deleting the context from memory.

.DESCRIPTION
 Clear the named context of it's stored networks, without deleting the context from memory.

.PARAMETER Name
 The name of the context stored in memory.

.EXAMPLE
 Clear-SCContext -Name default

 Clear the 'default' context of it's contents, but leave the empty store in memory.
#>

function Clear-SCContext {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $false, Position = 0)]
        [Alias("Context", "ContextName")]
        [string] $Name = "default"
    )

    if (-not (Test-ContextConfigured -Name $Name -ErrorAction Stop)) {
        Write-Error -Message "No context configured named $Name." -Exception ([qIPAM.Extensions.QIPSubnetCarverContextNotSetException]::new($Name)) -ErrorAction Stop
    }

    [qIPAM.Extensions.QIPSubnetCarverContext]::Instances[$Name].Clear()
}

<#
.SYNOPSIS
 Return an object that contains the root network, as well as all of the consumed networks in the named context.

.DESCRIPTION
 Return an object that contains the root network, as well as all of the consumed networks in the named context.

.PARAMETER Name
 The name of the context stored in memory.

.EXAMPLE
 Get-SCContext -Name default

 Return the contents of the default Context

.EXAMPLE
 Get-SCContext

 Return the contents of the all contexts stored in memory.
#>

function Get-SCContext {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $false, Position = 0)]
        [Alias("Context", "ContextName")]
        [string[]] $Name
    )

    if (-not ($MyInvocation.BoundParameters.ContainsKey('Name'))) {

        [qIPAM.Extensions.QIPSubnetCarverContext]::Instances.Keys | ForEach-Object -Process {

            [qIPAM.Models.QIPContextModel]::new($_, [qIPAM.Extensions.QIPSubnetCarverContext]::Instances[$_].RootCIDR, [qIPAM.Extensions.QIPSubnetCarverContext]::Instances[$_].ConsumedRanges)

        }

        return
    }

    $Name | ForEach-Object -Process {
        if (-not (Test-ContextConfigured -Name $_ -ErrorAction Stop)) {
            Write-Error -Message "No context configured named $_." -Exception ([qIPAM.Extensions.QIPSubnetCarverContextNotSetException]::new($_)) -ErrorAction Stop
        }

        [qIPAM.Models.QIPContextModel]::new($_, [qIPAM.Extensions.QIPSubnetCarverContext]::Instances[$_].RootCIDR, [qIPAM.Extensions.QIPSubnetCarverContext]::Instances[$_].ConsumedRanges)
    }
}

<#
.SYNOPSIS
 Reserve an IP address in a stored context.

.DESCRIPTION
 Reserve an IP address in a stored context. You can either reserve a specific IP, or the next available address space that meets your criteria.

.PARAMETER ContextName
 The name of the context stored in memory.

.PARAMETER ReserveCIDR
 The CIDR range(s) to reserve.

.PARAMETER ReserveCount
 The number of hosts to reserve.

.PARAMETER ReserveIPAddress
 The specific IP address range(s) to reserve.

.PARAMETER ReserveNextPointToPoint
 Reserve the next point-to-point network (/31) in the range.

.EXAMPLE
 Get-SCSubnet -ReserveCIDR 16 -ContextName default

 Reserves and returns the next available /16 in the default context.

.EXAMPLE
 Get-SCSubnet -ReserveNextPointToPoint -ContextName default

 Reserves and returns the next available point-to-point network (/31) in the default context.

.EXAMPLE
 Get-SCSubnet -ReserveIPAddress "10.0.1.0/24" -ContextName default

 Reserves and returns the 10.0.1.0/24 network from the default context, if it's available.

.EXAMPLE
 Get-SCSubnet -ReserveCount 250 -ContextName default

 Reserves the next available network from the default context with at least 250 usable hosts.
#>

function Get-SCSubnet {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ParameterSetName = "NEXT")]
        [ValidateRange(8, 31)]
        [int[]] $ReserveCIDR,

        [Parameter(Mandatory = $true, ParameterSetName = "NEXTP2P")]
        [Alias("P2P")]
        [switch] $ReserveNextPointToPoint,

        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ParameterSetName = "SPECIFIC")]
        [qIPAM.Models.IPAddressRange[]] $ReserveIPAddress,

        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = "COUNT")]
        [ValidateRange(0, 4294967296)]
        [UInt64[]] $ReserveCount,

        [Parameter(Mandatory = $false, Position = 1, ParameterSetName = "NEXT")]
        [Parameter(Mandatory = $false, Position = 0, ParameterSetName = "NEXTP2P")]
        [Parameter(Mandatory = $false, Position = 1, ParameterSetName = "SPECIFIC")]
        [Parameter(Mandatory = $false, Position = 1, ParameterSetName = "COUNT")]
        [Alias("Name", "Context")]
        [string] $ContextName = "default"
    )
    Begin {
        if (-not (Test-ContextConfigured -Name $ContextName -ErrorAction Stop)) {
            Write-Error -Message "No context configured named $ContextName." -Exception ([qIPAM.Extensions.QIPSubnetCarverContextNotSetException]::new($ContextName)) -ErrorAction Stop
        }
    }
    Process {

        if ($PSCmdlet.ParameterSetName -eq "NEXT") {

            foreach ($cidr in $ReserveCIDR) {
                [qIPAM.Extensions.QIPSubnetCarverContext]::Instances[$ContextName].Reserve($cidr)
            }

        }
        elseif ($PSCmdlet.ParameterSetName -eq "NEXTP2P") {
            [qIPAM.Extensions.QIPSubnetCarverContext]::Instances[$ContextName].Reserve(31)
        }
        elseif ($PSCmdlet.ParameterSetName -eq "SPECIFIC") {

            foreach ($ipAddress in $ReserveIPAddress) {
                [qIPAM.Extensions.QIPSubnetCarverContext]::Instances[$ContextName].Reserve($ipAddress)
            }

        }
        elseif ($PSCmdlet.ParameterSetName -eq "COUNT") {

            foreach ($count in $ReserveCount) {

                if ($count -le 2) {
                    $cidrNeeded = [qIPAM.Extensions.QIPSubnetCarverContext]::GetCIDRFromCount($count)
                }
                else {
                    $cidrNeeded = [qIPAM.Extensions.QIPSubnetCarverContext]::GetCIDRFromCount($count + 2)
                }

                [qIPAM.Extensions.QIPSubnetCarverContext]::Instances[$ContextName].Reserve($cidrNeeded)
            }
        }
        else {
            Write-Error -Message "Parameter set $($PSCmdlet.ParameterSetName) has not been implemented" -ErrorAction Stop
        }

    }
}

<#
.SYNOPSIS
 Set or reset a root network in memory to be carved into subnets.

.DESCRIPTION
 Set or reset a root network in memory to be carved into subnets.

.PARAMETER Name
 The name of the context stored, or to be stored, in memory.

.PARAMETER ConsumedIPRanges
 Any consumed IP address range(s) that should be considered already consumed in the in-memory context.

.EXAMPLE
 Set-SCContext -RootAddressSpace "10.0.0.0/8" -Name default

 Create a context in memory named "default" with a root range of 10.0.0.0/8. This will be an empty network.

.EXAMPLE
 Set-SCContext -RootAddressSpace "10.0.0.0/8" -Name default -ConsumedIPRanges "10.0.1.0/16","10.0.2.0/16"

 Create a context in memory named "default" with a root range of 10.0.0.0/8, and the ranges 10.0.1.0/16 and 10.0.2.0/16 already occupied.
#>

function Set-SCContext {
    [CmdletBinding()]
    [Alias("New-SCContext", "Add-SCContext", "Reset-SCContext")]
    Param(
        [Parameter(Mandatory = $true, Position = 0)]
        [qIPAM.Models.IPAddressRange] $RootAddressSpace,

        [Parameter(Mandatory = $false, Position = 1)]
        [Alias("Context", "ContextName")]
        [string] $Name = "default",

        [Parameter(Mandatory = $false, Position = 2)]
        [qIPAM.Models.IPAddressRange[]] $ConsumedIPRanges = $null
    )

    [qIPAM.Extensions.QIPSubnetCarverContext]::SetContext($Name, $RootAddressSpace, $ConsumedIPRanges)
}

<#
.SYNOPSIS
 Test if a network configuration is valid.

.DESCRIPTION
 Test if a network configuration is valid given a root network and a list of contained subnetworks.

.PARAMETER RootIPRange
 The root IP range of the virtual network to test.

.PARAMETER ConsumedIPRanges
 Consumed ranges within the virtual network being tested.

.EXAMPLE
 Test-SCNetworkIsValid -RootIPRange "10.0.0.0/8" -ConsumedIPRanges "10.1.0.0/16","10.2.0.0/16","10.1.0.0/24"

 Test if a list of consumed ranges can all fit into a given root. This example would fail, and indicate that the 10.1.0.0/24 range doesn't fit.
#>

function Test-SCNetworkIsValid {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true, Position = 0)]
        [qIPAM.Models.IPAddressRange] $RootIPRange,

        [Parameter(Mandatory = $false, Position = 1)]
        [qIPAM.Models.IPAddressRange[]] $ConsumedIPRanges
    )

    [qIPAM.Extensions.QIPSubnetCarverContext]::TestNetwork($RootIPRange, $ConsumedIPRanges)
}

<#
.SYNOPSIS
 Remove a consumed range from a context.

.DESCRIPTION
 Remove a consumed range from an in-memory context, marking that address range as free. Note this will only remove exact matches, not chunks.

.PARAMETER IPAddressRange
 The IP address range(s) to remove from the in-memory context.

.PARAMETER ContextName
 The name of the in-memory context to modify. Defaults to "default".

.EXAMPLE
 Remove-SCSubnet -IPAddressRange "10.1.0.0/16","10.2.0.0/16"

 Removes the ranges 10.1.0.0/16 and 10.2.0.0/16 from the in-memory context named "default".
#>
function Remove-SCSubnet {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [qIPAM.Models.IPAddressRange[]] $IPAddressRange,

        [Parameter(Mandatory = $false, Position = 1)]
        [Alias("Name", "Context")]
        [string] $ContextName = "default"
    )
    Begin {
        if (-not (Test-ContextConfigured -Name $ContextName -ErrorAction Stop)) {
            Write-Error -Message "No context configured named $ContextName." -Exception ([qIPAM.Extensions.QIPSubnetCarverContextNotSetException]::new($ContextName)) -ErrorAction Stop
        }
    }
    Process {
        $IPAddressRange | ForEach-Object -Process {

            if ([qIPAM.Extensions.QIPSubnetCarverContext]::Instances[$ContextName].ConsumedRanges.Contains($_)) {
                [qIPAM.Extensions.QIPSubnetCarverContext]::Instances[$ContextName].Remove($_)
            }
            else {
                Write-Warning -Message "Range $_ was not found in context $ContextName, so nothing was removed."
            }
        }
    }
}