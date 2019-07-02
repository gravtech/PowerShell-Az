<#
    Purpose:
        The purpose of this Script is to automate the process of create VM's using the Naming standards
        developed for Global Lending Solutions Azure environment


    Version History
        v2.1, 04/21/17:     Added ability to include in Availability Set, bkg
        v2.2, 04/21/17:     Added the ability to use managed storage, bkg
        v2.3, 4/21/18:      Added setting the subscription to the Login
        v2.4, 2/2/18:       Changed the login keys to autopopulate based on logged in user
        v2.5, 2/2/18:       Added options to add data disks, encrypt the VM and backup the VM
        v2.6, 2/13/18:      Fixed the Add Data Disks, encryption and backup sections, bkg
        v2.7, 2/28/18:      Changed VM Size example to V3
                            Added disclaimer for Managed Disks and Availability Sets
        v2.8, 3/6/18        Changed the Storage Type for HDD to Read Only Geo Replicated
        v3.0, 3/22/18:      Added the ability to set a static IP Address during creation
        v3.1, 3/28/18:      Added numbered lists to the choices so just a number needs to be typed
                            Added Ubuntu Servers as an option
        v3.2, 6/21/18:      Added option to run first backup.
        v3.3, 6/27/18:      Added prompt if Machine Type is DS or ES to ask for storage type
                            Added section to display selected properties and prompt to proceed before creation
        v3.4, 6/28/18:      Added Red Hat as a server type option
                            Added code for Windows 10 as a server type but commented it out of the list
                            for selecting OS because you have to have an subscription to deploy windows 10
                            (https://docs.microsoft.com/en-us/azure/virtual-machines/windows/client-images#eligible-offers)
	    v3.5, 8/27/18:		Change $NetworkName variable from ($VMName.Substring(3,3)).ToUpper() to $vmname.split("-")[1]  to allow for longer Resource Group names
        v3.6, 2/11/19:      Added multiple subscription selection.
        v5.0, 6/14/19:      Converted to new AZ commands to replace AzureRM commands, fixed minor errors, bkg
        v5.1, 6/18/19:      Adjusted to make it easier to automatically log on as someone other than the user
                            logged into the machine.
        v5.2, 6/19/19       Added option to use Accelerated Networking on supported VMs


    Author:     Bryan K Gravely
    Location:   \\vault.atl.glsllc.com\AzureScripts\1-CreateResources\

#>

#region Troubleshooting
    If ($preRunVariables.count -eq 0)
    {
        [array]$preRunVariables = ([array](Get-Variable).Name) + "variable" + "preRunVariables"
    }
    
    <#
    The above line will run at the beginning of the script each time to get a list of all the variables in memory
    before the script is run so that the code below can be run at anytime to remove all of the varables that have
    been added since that time from the session

    foreach ($variable in (Get-Variable).name)
    {
        If ($variable -notin $preRunVariables)
        {
            write-host "Removing $variable" -foregroundcolor darkcyan
            Remove-Variable $variable
        }
    }

    #>
#endregion

#region Functions
    Function FCN_ConnectAZAccount
    {
        write-host
        write-host "Enter the e-mail address you would like to use to log into Azure" -ForegroundColor Magenta
        $azUser = read-host
        while ((($azUser.split("@")).count -ne 2) -or ($azuser.split("@")[1].split(".").count -lt 2))
        {
            write-host "Invalid E-mail address." -ForegroundColor Red
            write-host "Enter the e-mail address you would like to use to log into Azure" -ForegroundColor Magenta
            write-host "Example jdoe@email.com" -ForegroundColor Gray
            $azUser = Read-Host
        }
        write-host "Enter the password for $azUser" -ForegroundColor Magenta
        $azPW = Read-Host -AsSecureString
        $azCred = New-Object System.Management.Automation.PSCredential($azUser, $azPW)
        Connect-AZAccount -Credential $azCred
    }

    Function FCN_SelectSubscription
    {
        $subscriptionList = @()
        $subscriptionList = Get-AzSubscription
        If ($subscriptionList.count -eq 1)
        {
            $subscription = (Get-AZSubscription)[0]
            $subscriptionName = $subscription.Name
            write-host "Only one subscription was found.  $subscriptionName will be used" -ForegroundColor DarkCyan
        }
        Else
        {
            write-host "List of available Subscriptions:" -ForegroundColor DarkCyan
            FCN_DisplayListWithNumbers $subscriptionList.Name
            write-host "Enter the number of the subscription you would like to use." -ForegroundColor DarkCyan
            $selection = FCN_PromptNumberBetweenXandY 1 $subscriptionList.Count
            $subscription = (Get-AZSubscription)[$selection - 1]
        }
    
        Return $subscription
    }

    Function FCN_GenCreds
    {
        $adminname = 'glsadmin'
        $adminPassword = ConvertTo-SecureString 'P~W.6,"fE&isN' -AsPlainText -Force
        $Cred = New-Object System.Management.Automation.PSCredential($adminName, $adminPassword)

        Return $Cred
    }

    Function FCN_GenNICName
    {
        Param(
            [Parameter(Mandatory=$True)]
            [String]$VMName
        )

        $nicname = $VMName.ToLower() + “_nic01”

        Return $nicname
    }

    Function FCN_GenOSDiskName
    {
        Param(
            [Parameter(Mandatory=$True)]
            [String]$VMName
        )

        $OSDiskName = $VMName + “_OSDisk.vhd”

        Return $OSDiskName
    }

    Function FCN_GenVMSAName
    {
        Param(
            [Parameter(Mandatory=$True)]
            [String]$VMName
        )

        $SAname = "srvstore" + ($VMName.Replace("-", "")).ToLower()

        Return $SAname
    }

    Function FCN_PromptOfferName
    {
        Param(
            [Parameter(Mandatory=$True)]
            [String]$location,
            [Parameter(Mandatory=$True)]
            [String]$vmPubName
        )

        $OffersList = (Get-AzVMImageOffer –Location $location –PublisherName $vmPubName).Offer
        write-host "Available Offers" -ForegroundColor DarkCyan
        FCN_DisplayListWithNumbers $OffersList
        $OfferChoice = FCN_PromptNumberBetweenXandY 1 ($OffersList.count)
        $Offer = $offersList[$OfferChoice -1]

        Return $Offer
    }

    Function FCN_PromptVMSize
    {
        Param(
            [Parameter(Mandatory=$True)]
            [String]$location,
            [Parameter(Mandatory=$True)]
            [Boolean]$useSSD
        )
    
        # Prompt for VM Size
        $VMSizeList = Get-AzVMSize -location $location
        $propertyList = "Number", "Name", "NumberOfCores", "MemoryInMB", "MaxDataDiskCount"
        If ($useSSD)
        {
            $suggestedVMSizeList = $VMSizeList | where-object {$_.Name.EndsWith("s_v3")} | sort-object NumberOfCores
            write-host "Suggested SSD VM Sizes" -ForegroundColor DarkCyan
            FCN_DisplayObjectListWithNumbers $suggestedVMSizeList $propertyList -includeOther $True
            $VMChoice = FCN_PromptNumberBetweenXandY 1 ($suggestedVMSizeList.count + 1)
            If ($VMChoice -eq ($suggestedVMSizeList.count + 1))
            {
                $VMSizeList_SSD1 = $VMSizeList | where-object {$_.Name.EndsWith("s")}
                $VMSizeList_SSD2 = $VMSizeList | where-object {$_.Name.EndsWith("s_v2")}
                $VMSizeList_SSD3 = $VMSizeList | where-object {$_.Name.EndsWith("s_v3")}
                $VMSizeList_SSD = ($VMSizeList_SSD1 + $VMSizeList_SSD2 + $VMSizeList_SSD3) | sort-object -Property NumberOfCores
                write-host "All Solid State Sizes" -ForegroundColor DarkCyan
                FCN_DisplayObjectListWithNumbers $VMSizeList_SSD $propertyList
                $VMSize = $VMSizeList_SSD[(FCN_PromptNumberBetweenXandY 1 $VMSizeList_SSD.count) -1]
            }
            Else
            {
                $vmsize = $suggestedVMSizeList[$VMChoice - 1]
            }
        }
        Else
        {
            $suggestedVMSizeListA = $VMSizeList | where-object {$_.Name.startswith("Standard_A")}
            $suggestedVMSizeListA = $SuggestedVMSizeListA | where-object {-not($_.Name.endswith("s"))}
            $suggestedVMSizeListA = $suggestedVMSizeListA | where-object {$_.Name.EndsWith("v2")}
            $suggestedVMSizeListD = $VMSizeList | where-object {$_.Name.startswith("Standard_D")}
            $suggestedVMSizeListD = $suggestedVMSizeListD | where-object {$_.Name.EndsWith("v3")}
            $suggestedVMSizeListD = $suggestedVMSizeListD | where-object {-not($_.Name.EndsWith("s_v3"))}
            $suggestedVMSizeList = ($suggestedVMSizeListA + $suggestedVMSizeListD)
        
            write-host "Suggested Non-SSD VM Sizes" -ForegroundColor DarkCyan
            FCN_DisplayObjectListWithNumbers $suggestedVMSizeList $propertyList -includeOther $True
            $VMChoice = FCN_PromptNumberBetweenXandY 1 ($suggestedVMSizeList.count + 1)
            If ($VMChoice -eq ($suggestedVMSizeList.count + 1))
            {
                $VMSizeList_HDD = $VMSizeList | where-object {-not($_.Name.EndsWith("s"))}
                $VMSizeList_HDD = $VMSizeList_HDD | where-object {-not($_.Name.EndsWith("s_v2"))}
                $VMSizeList_HDD = $VMSizeList_HDD | where-object {-not($_.Name.EndsWith("s_v3"))}
                $VMSizeList_HDD = $VMSizeList_HDD | sort-object -Property NumberOfCores
                write-host "All Non-SSD VM Sizes" -ForegroundColor DarkCyan
                FCN_DisplayObjectListWithNumbers $VMSizeList_HDD $propertyList
                $VMSize = $VMSizeList_HDD[(FCN_PromptNumberBetweenXandY 1 $VMSizeList_HDD.count) -1]
            }
            Else
            {
                $vmsize = $suggestedVMSizeList[$VMChoice - 1]
            }

        }

        Return $VMSize
    }

    Function FCN_PromptSKUName
    {
        Param(
            [Parameter(Mandatory=$True)]
            [String]$location,
            [Parameter(Mandatory=$True)]
            [String]$vmPubName,
            [Parameter(Mandatory=$True)]
            [String]$vmOfferName
        )

        $SKUs = (Get-AzVMImageSku -Location $location -Publisher $vmPubName -Offer $vmOfferName).skus
        write-host "Available SKUs:" -ForegroundColor DarkCyan
        FCN_DisplayListWithNumbers $SKUs
        $SkuNumber = FCN_PromptNumberBetweenXandY 1 ($Skus.count)
        $sku = $SKUs[$SkuNumber-1]

        Return $Sku
    }

    Function FCN_PromptOS
    {
        $vmOSList = "Windows Server", "SQL", "Ubuntu", "Red Hat", "Windows 10"
        write-host "What type of Server would you like to create?" -ForegroundColor DarkCyan
        FCN_DisplayListWithNumbers $vmOSList
        $vmOSChoice = FCN_PromptNumberBetweenXandY 1 $vmOSList.count
        $vmOS = $vmOSList[$vmOSChoice -1]

        Return $vmOS
    }

    Function FCN_PromptYorN
    {
        Param(
            [Parameter(Mandatory=$False)]
            [int]$bufferLength
        )

        $text = "Please answer 'y' or 'n'"
        write-host $text.PadLeft($text.length + $bufferLength) -ForegroundColor Magenta
        $YorN = (Read-Host).ToLower()
        While("y", "n" -notcontains $YorN)
        {
            $text = "Invalid Entry."
            write-host $text.PadLeft($text.length + $bufferLength) -ForegroundColor Red
            $text = "Please answer 'y' or 'n'"
            write-host $text.PadLeft($text.length + $bufferLength) -ForegroundColor Magenta
            $YorN = Read-Host
        }

        If ($YorN -eq 'y')
        {
            Return $True
        }
        Else
        {
            Return $False
        }
    }

    Function FCN_PromptNewIPAddress
    {
        Param(
            [Parameter(Mandatory=$True)]
            [String]$subnetName,
            [Parameter(Mandatory=$True)]
            [String]$VMRGName
        )

        $vNetNicList = ((Get-AzNetworkInterface -ResourceGroupName $VMRGName) | Where-object {($_.IpConfigurations.subnet.id).split("/")[($_.IPConfigurations.subnet.id.split("/").count) -1] -eq $subnetName})
        [array]$lastOctetList = $Null
        [array] $usedIPList = $Null
        foreach ($nic in $vNetNicList)
        {
            $lastOctetList += ($nic.ipconfigurations[0].PrivateIPAddress).Split(".")[3]
        }
        $lastOctetList = $lastOctetList | sort-object {[int]$_}
        foreach ($octet in $lastOctetList)
        {
            $usedIPList += ($Octets1through3 + $octet)
        }
        $sampleIP = ($vNetNicList[0].ipconfigurations[0].privateipaddress)
        $prefix = $sampleIP.Split(".")[0] + "." + $sampleIP.Split(".")[1] + "." + $sampleIP.Split(".")[2] + "."
        write-host "The following IP Address in the $subnetName Subnet Are in use:" -ForegroundColor DarkCyan
        write-host ($usedIPList -join "`n") -ForegroundColor Cyan
        $example = $prefix + "19"
        write-host "Please enter the final octet of the IP Address you would like to assign.  For example, for $example, only enter 19." -ForegroundColor DarkCyan
        $VMLastOctet = FCN_PromptNew $lastOctetList "IP Address"
        
        Return $prefix + $VMLastOctet
    }

    Function FCN_PromptNumberBetweenXandY
    {
        Param(
            [Parameter(Mandatory=$True)]
            [int]$top,
            [Parameter(Mandatory=$True)]
            [int]$bottom
        )
    
        do {
            try {
                $numOk = $true
                write-host "Enter a number between $top-$bottom" -ForegroundColor Magenta
                [int]$Number = Read-host
                } # end try
            catch {$numOK = $false}
            } # end do 
        until (($Number -ge $top -and $Number -le $bottom) -and $numOK)
    
        Return $Number
    }

    Function FCN_DisplayObjectListWithNumbers
    {
        Param(
            [Parameter(Mandatory=$True)]
            [array]$List,
            [Parameter(Mandatory=$True)]
            [array]$propertyList,
            [Parameter(Mandatory=$False)]
            [string]$sortedProperty,
            [Parameter(Mandatory=$False)]
            [Boolean]$includeOther,
            [Parameter(Mandatory=$False)]
            [boolean]$includeNew
            )

        $i=1
        [array]$objectList = @()
        If($sortedproperty -eq "")
        {
            $sortedList = $list
        }
        Else
        { 
            $sortedList = $List | sort-object $sortedProperty
        }
        foreach ($item in $sortedList)
        {
            $object = New-Object -TypeName psobject
            foreach ($property in $propertyList)
            {
                If ($property -eq "Number")
                {
                    $value = $i
                }
                Else
                {
                    $value = $item | select-object -ExpandProperty $property
                }
                $object | Add-Member -MemberType NoteProperty -name $property -Value $value.ToString()
            }
            $objectList += $object
            $i += 1
        }
        If ($includeOther)
        {
            $object = New-Object -TypeName psobject
            $Object | Add-Member -MemberType NoteProperty -name "Number" -value $i
            $object | Add-Member -MemberType NoteProperty -name $propertyList[1] -Value "Other"
            $objectList += $object
        }
        If ($includeNew)
        {
            $object = New-Object -TypeName psobject
            $Object | Add-Member -MemberType NoteProperty -name "Number" -value $i
            $object | Add-Member -MemberType NoteProperty -name $propertyList[1] -Value "Create New"
            $objectList += $object
        }
        write-host ($objectList | format-table | out-string) -ForegroundColor Cyan

    }

    Function FCN_DisplayListWithNumbers
    {
        Param(
            [Parameter(Mandatory=$True)]
            [array]$List,
            [Parameter(Mandatory=$False)]
            [int]$padLength
            )

        $i=0
        foreach ($item in $List)
        {
            $i += 1
            write-host "$i. $item".PadLeft("$i. $item".Length + $padLength) -ForegroundColor cyan
        }
    }

    Function FCN_PromptNew
    {
        Param(
            [Parameter(Mandatory=$True)]
            [array]$list,
            [Parameter(Mandatory=$True)]
            [string]$description
            )

        $newitem = Read-host
        while (($list).ToLower() -contains $newitem.ToLower())
        {
            write-host "Invalid Entry.  The $description $newitem already Exists" -ForegroundColor Red
            write-host "Enter a new $description" -ForegroundColor Magenta
            $newitem = read-host
        }

        Return $newitem

    }

    Function FCN_PromptExisting
    {
        Param(
            [Parameter(Mandatory=$True)]
            [array]$list,
            [Parameter(Mandatory=$True)]
            [string]$description,
            [Parameter(Mandatory=$False)]
            [boolean]$includeAddNew
            )

        If ($includeAddNew)
        {
            $list = $list + "Create New $description"
        }
        FCN_DisplayListWithNumbers $list 3
        
        Return $list[(FCN_PromptNumberBetweenXandY 1 $list.count) - 1]
        
    }

    Function FCN_CreateRG
    {
        Param(
            [Parameter(Mandatory=$True)]
            [string]$VMRegionName
        )

        $RGNameList = (Get-AzResourceGroup | where ResourceID -Match $subscription.Id).ResourceGroupName | sort
        $newRGName = FCN_PromptNew $RGNameList "Resource Group"

        write-host "Would you like to place the Resource Group in the $VMRegionName Region like the VM?" -ForegroundColor DarkCyan
        If (FCN_PromptYorN 3)
        {
            $newRGRegionName = $VMRegionName
        }
        Else
        {
            $RegionNameList = (Get-AZLocation | where-object {($_.DisplayName).split(" ") -contains "US" }).DisplayName | sort
            write-host "In which Azure Region would you like to create the new Resource Group?" -ForegroundColor DarkCyan
            $newRGRegionName = FCN_PromptExisting $regionNameList "Azure Region"
        }

        write-host "Creating Resource Group Named $newRGName in the $newRGRegionName Region" -ForegroundColor Green
        Return New-AzResourceGroup -Name $newRGName -Location $newRGRegionName

    }
#endregion

#region set C-Drive and clear
    c:
    cd\
    Clear
#endregion

#region Login to Azure
    FCN_ConnectAZAccount

    $subscription = FCN_SelectSubscription
    Select-AzSubscription -Subscription $subscription.Name

    
#endregion

#region Prompt for Azure Region
    write-host
    write-host "In which Azure Region would you like to create your VM?" -ForegroundColor DarkCyan
    $RegionNameList = (Get-AZLocation | where-object {($_.DisplayName).split(" ") -contains "US" }).DisplayName | sort
    $VMRegionName = FCN_PromptExisting $RegionNameList "Azure Region"
    $vmRegion = Get-AZLocation | where-object {$_.DisplayName -eq $vmRegionName}
#endregion

#region Prompt for Resource Group
    write-host
    $RGNameList = (Get-AzResourceGroup | where-object { ($_.ResourceID).split("/") -contains $subscription.Id }).ResourceGroupName | sort
    write-host "In which Resource Group would you like to create your new VM?" -ForegroundColor DarkCyan
    $VMRGName = FCN_PromptExisting $RGNameList "Resource Group" -includeAddNew $True
    If ($VMRGName -eq "Create New Resource Group")
    {
        write-host "What would you like to Name the new Resource Group?"
        $VMRG = FCN_PromptNew $RGNameList "Resource Group"
    }
    Else
    {
        $VMRG = Get-AzResourceGroup -Name $VMRGName
    }
#endregion

#region Prompt for New VM Name
    $VMNameList = (Get-AZVM -ResourceGroupName $VMRGName).Name
    write-host "What would you like to name the new VM?" -ForegroundColor DarkCyan
    $VMName = FCN_PromptNew $VMNameList "VM Name"
#endregion

#region Prompt for Virtual Network
    write-host
    [array]$vNetNameList = (Get-AZVirtualNetwork -ResourceGroupName $VMRGName).Name | sort
    If ($vNetNameList.count -eq 1)
    {
        $VMvNetName = $vNetNameList[0]
        write-host "Only one Virtual Network Was found in the $VMRGNam Resouce Group" -ForegroundColor DarkCyan
        write-host "The $VMvNetName Virtual Network will be used"-ForegroundColor Green
    }
    Else
    {
        write-host "In which Virtual Network would you like to create your VM?" -ForegroundColor DarkCyan
        $VMvNetName = FCN_PromptExisting $vNetNameList "Virtual Network"
    }

    $VMvNet = Get-AzVirtualNetwork -Name $VMvNetName -ResourceGroupName $VMRGName
#endregion

#region Prompt for Subnet
    write-host
    [array]$subnetNameList = (Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $VMvNet | where-object {$_.Name -ne "GatewaySubnet"}).Name | sort
    If ($subnetNameList.count -eq 1)
    {
        $VMsubnetName = $subnetNameList[0]
        write-host "Only one Subnet was found in the $VMvNetName Virtual Network" -ForegroundColor DarkCyan
        write-host "The $VMSubnetName Subnet will be used." -ForegroundColor Green
    }
    Else
    {
        write-host "In which Subnet would you like to create your VM?" -ForegroundColor DarkCyan
        $vmSubnetName = FCN_PromptExisting $subnetNameList "Subnet"
    }

    $VMsubnet = Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $VMvNet -Name $VMsubnetName
#endregion

#region Prompt for NIC Name
    $vmNicName = $vmName+"_nic01"
    write-host "The default NIC Name for this Server is $vmNicName" -ForegroundColor DarkCyan
    write-host "Would you like to named the primary Network Interface $vmNicName" -ForegroundColor DarkCyan
    If (-not(FCN_PromptYorN))
    {
        $nicNameList = (Get-AzNetworkInterface -ResourceGroupName $VMRGName).Name
        write-host "What would you like to name the primary Network Interface for $vmName" -ForegroundColor DarkCyan
        $vmNicName = FCN_PromptNew $nicNameList "Network Interface Name"
    }
#endregion

#region Prompt for NSG
    write-host
    
    $nsgNameList = (Get-AzNetworkSecurityGroup).Name
    write-host "Which Network Security Group would you like to put the NIC into?" -ForegroundColor DarkCyan
    FCN_DisplayListWithNumbers $nsgNameList
    $vmNSGName = $nsgNameList[(FCN_PromptNumberBetweenXandY 1 $nsgNameList.count) - 1]
    $vmNSG = Get-AzNetworkSecurityGroup | where-object {$_.name -eq $nsgName}
    $vmNSGID = $vmNSG.Id
#endregion

#region Prompt for Static IP
    write-host
    write-host "Would you like to assign a Static IP Address?"
    $setStaticIP = FCN_PromptYorN
    If ($setSTaticIP)
    {
        $VMIPAddress = FCN_PromptNewIPAddress $VMsubnetName $VMRGName
        write-host "Static IP Address: $VMIPAddress" -ForegroundColor DarkCyan
    }        
    Else
    {
        write-host "Dynamic IP Address selected" -ForegroundColor DarkCyan
    }
#endregion

#region Prompt for AvailabilitySet
    write-host
    write-host "Would you like to put this VM into an Availability Set?" -ForegroundColor DarkCyan
    write-host "Availability Sets are for setting up redundant instances of the same VM" -ForegroundColor Gray
    $useASet = FCN_PromptYorN
    If ($useASet)
    {
        $VMASetName = "ASet_$VMName"
        write-host "     The Default Name for an Availability Set for this VM is $VMASetName"
        write-host "     Would you like to use this name for the availability Set?"
        If (-not(FCN_PromptYorN 5))
        {
            write-host "     Please enter the name of the availability set for this VM." -ForegroundColor Magenta
            $VMASetName = read-host
        }
        $VMASet = Get-AzAvailabilitySet -name $VMASetName -ResourceGroupName $VMRGName -ErrorAction Ignore
        If ($VMASet)
        {
            write-host "Availability Set $VMASetName already exists, using existing Availability Set" -ForegroundColor DarkCyan
            $VMASetID = $VMASet.Id
        }
    }
#endregion

#region Prompt for HHD or SSD
    write-host
    write-host "VM's are available with Standard Hard Drives or Solid State Drives" -ForegroundColor DarkCyan
    write-host "Would you like to upgrade the machine to use Solid State Drives?" -ForegroundColor DarkCyan
    $useSSD = FCN_PromptYorN
    If ($useSSD)
    {
        $vmStorageSKU = "Premium_LRS"
    }
    Else
    {
        $vmStorageSKU = "Standard_LRS"
    }
#endregion

#region Prompt for Managed or Unmanaged Disks
    write-host
    if ($useASet -and $VMAset)
    {
        If ($VMAset.sku -eq "Aligned")
        {
            write-host "The Availability Set for this VM was created for VM's with Managed Disks." -ForegroundColor DarkCyan
            write-host "Managed Disks will be used for this VM" -ForegroundColor DarkCyan
            $useManagedDisks = $True
        }
        Else
        {
            write-host "The Availability Ser for this VM was created for VM's without Managed Disks." -ForegroundColor DarkCyan
            write-host "Managed Disks will not be used for this VM." -ForegroundColor DarkCyan
            $vmSAName = "srvstore"+$vmName.replace("-", "").ToLower()
            write-host "The default Storage Account Name for this VM is $vmSAName" -ForegroundColor DarkCyan
            write-host "Would you like to use the $vmSAName Storage Account for this VM?" -ForegroundColor DarkCyan
            if (FCN_PromptYorN)
            {
                $VMSA = Get-AZStorageAccount -name $VMSAName -ResourceGroupName $VMRGName
            }
            Else
            {
                write-host "What would you like to name the storage account for this VM?" -ForegroundColor Magenta
                $vmSAName = read-host
                while (-not((Get-AzStorageAccountNameAvailability $vmSAName).NameAvailable))
                {
                    write-host "Invalid Entry.  The Storage Account $vmSAName is already in use in Azure" -ForegroundColor Red
                    write-host "What would you like to name the storage account for this VM?" -ForegroundColor Magenta
                    $vmSAName = read-host
                }
                $vmSA = New-AzStorageAccount -Name $vmSAName -ResourceGroupName $vmRGName
            }
        }
    }
    Else
    {
        write-host
        write-host "Would you like to use managed disks?" -ForegroundColor DarkCyan
        write-host "Always select Yes unless there is a specific reason to not use Managed Disks" -ForegroundColor Gray
        $useManagedDisks = FCN_PromptYorN
        If ($useManagedDisks)
        {
            if ($useASet)
            {
                write-host "Creating Availability Set $VMAsetName" -ForegroundColor Green
                $VMAset = New-AzAvailabilitySet -ResourceGroupName $VMRGName -Location $vmRegionName -Name $VMAsetName -sku Aligned -PlatformUpdateDomainCount 5 -PlatformFaultDomainCount 2
                $VMAsetID = $VMAset.Id
            }
            
        }
        Else
        {
            if ($useASet)
            {
                write-host "Creating Availability Set $VMAsetName" -ForegroundColor Green
                $VMAset = New-AzAvailabilitySet -ResourceGroupName $VMRGName -Location $vmRegionName -Name $VMAsetName -sku CLASSIC -PlatformUpdateDomainCount 5 -PlatformFaultDomainCount 2
                $VMAsetID = $VMAset.Id
            }
            $vmSAName = "srvstore"+$vmName.replace("-", "").ToLower()
            write-host "The default Storage Account Name for this VM is $vmSAName" -ForegroundColor DarkCyan
            write-host "Would you like to use the $vmSAName Storage Account for this VM?" -ForegroundColor DarkCyan
            if (FCN_PromptYorN)
            {
                while ((Get-AzStorageAccountNameAvailability $vmSAName).NameAvailable)
                {
                    write-host "Creating Storage Account $VMSAName..." -ForegroundColor Green
                    $vmSA = New-AZStorageAccount -Name $vmSAName -ResourceGroupName $VMRGName -SkuName $VMStorageSKU -Location $VMRegionName
                }
                Else
                {
                    write-host "Getting existing Storage Account $VMSAName..." -ForegroundColor Green
                    $VMSA = Get-AZStorageAccount -name $VMSAName -ResourceGroupName $VMRGName
                }
            }
            Else
            {
                write-host "What would you like to name the storage account for this VM?" -ForegroundColor Magenta
                $vmSAName = read-host
                while (-not((Get-AzStorageAccountNameAvailability $vmSAName).NameAvailable))
                {
                    write-host "Invalid Entry.  The Storage Account $vmSAName is already in use in Azure" -ForegroundColor Red
                    write-host "What would you like to name the storage account for this VM?" -ForegroundColor Magenta
                    $vmSAName = read-host
                }
                $vmSA = New-AzStorageAccount -Name $vmSAName -ResourceGroupName $vmRGName -SkuName $VMStorageSKU -Location $VMRegionName
            }
        }           
        
    }
#endregion

#region Prompt for VM Size
    write-host
    $VMSize = FCN_PromptVMSize $VMRegionName $useSSD
    $VMSizeName = $VMSize.Name
#endregion

#region Prompt for OS Information
    write-host
    $vmOS = FCN_PromptOS
    If ($vmOS -eq "Windows Server")
    {
        $vmPubName = "MicrosoftWindowsServer"
        $vmOfferName = "windowsserver"
    }
    Elseif ($vmOS -eq "SQL")
    {
        $vmPubName = "MicrosoftSQLServer"
        $vmOfferName = FCN_PromptOfferName $VMRegionName $vmPubName
    }
    Elseif ($vmOS -eq "Windows 10")
    {
        $vmPubName = "MicrosoftWindowsDesktop"
        $vmOfferName = "Windows-10"
    }
    Elseif ($vmOS -eq "Red Hat")
    {
        $vmPubName = "RedHat"
        $vmOfferName = "RHEL"
    }
    Else
    {
        $vmPubName -eq "Canonical"
    }
    $vmSkuName = FCN_PromptSKUName $VMRegionName $vmPubName $vmOfferName
#endregion

#region Prompt for AcceleratedNetworking
If (("Windows Server", "SQL" -contains $vmOS) -and ((($vmSize.Name -match "v3") -and ($VMSize.NumberOfCores -ge 4)) -or (($vmSize.Name -match 'v2') -and ($vmsize.NumberOfCores -ge 2))))
{
    write-host "The VM Size you have selected supports Accelerated Networking." -ForegroundColor DarkCyan
    write-host "Would you like to enable Accelerated Networking for this VM?" -ForegroundColor DarkCyan
    $useAcceleratedNetworking = FCN_PromptYorN
}
#endregion

#region Prompt for Boot Diagnostics
    write-host
    write-host "Would you like to enable Boot Diagnostics"
    $useBootDiags = FCN_PromptYorN
    If ($useBootDiags)
    {
        write-host "Which Storage Account would you like to store Boot Diagnostics in?"
        $saNameList = (Get-AZStorageAccount).StorageAccountName #| where-object {$_.sku.Name -eq $vmStorageSKU}
        $vmDiagsSAName = FCN_PromptExisting $saNameList "Storage Account"
        $vmDiagsSA = Get-AZStorageAccount | where-object {$_.StorageAccountName -eq $vmDiagsSAName}
        $vmDiagsSAID = $VMDiagsSA.Id
    }
#endregion

#region Display Selected Options
    write-host
    write-host "Here are the settings you have selected:" -foregroundcolor darkCyan
    write-host "VM Name:                   $VMName" -ForegroundColor Cyan
    write-host "VM Size:                   $VMSizeName" -ForegroundColor Cyan
    write-host "VM Type:                   $vmOS" -ForegroundColor Cyan
    write-host "VM OS:                     $vmSkuName" -ForegroundColor Cyan
    If ($useManagedDisks)
    {
        write-host "Storage Name:              Managed Disks" -ForegroundColor Cyan
    }
    Else
    {
        write-host "Storage Name:              $vmSAName" -ForegroundColor Cyan
    }
    write-host "Storage Type:              $vmStorageSKU" -ForegroundColor Cyan
    write-host "Managed Disks:             $useManagedDisks" -ForegroundColor Cyan
    If ($useAvailabilitySet)
    {
        write-host "Availability Set:          $vmASetName" -ForegroundColor Cyan
    }
    write-host "Virtual Network:           $VMvNetName" -ForegroundColor Cyan
    write-host "Subnet:                    $VMsubnetName" -ForegroundColor Cyan
    write-host "NSG Name:                  $vmNSGName" -ForegroundColor Cyan
    write-host "NIC Name:                  $VMNICName" -ForegroundColor Cyan
    If ($setStaticIP)
    {
        write-host "Static IP:                 $VMIPAddress" -ForegroundColor Cyan
    }
    Else
    {
        write-host "IP Address:                DHCP" -foregroundcolor Cyan
    }
    If ($useAcceleratedNetworking)
    {
        write-host "Accellerated Networking:   Enabled" -foregroundcolor Cyan
    }
    Elseif ($useAcceleratedNetworking -eq $False)
    {
        write-host "Accellerated Networking:   Disabled" -foregroundcolor Cyan
    }
    Else
    {
        write-host "Accellerated Networking:   N/A" -foregroundcolor Cyan
    }

    write-host
    write-host "Would you like to proceed with these settings" -ForegroundColor DarkCyan
    If (-not(FCN_PromptYorN))
    {
        write-host "Creation Aborted" -ForegroundColor Red
        break
    }
#endregion

#region Create the VM config
    $vmCreds = FCN_GenCreds
    write-host
    write-host "Creating the VM Config..." -ForegroundColor Green
    If ($useASet)
    {
        $VM = New-AzVMConfig -VMName $VMName -VMSize $VMSizeName -AvailabilitySetId $vmASetID
    }
    Else
    {
        $VM = New-AzVMConfig -VMName $VMName -VMSize $VMSizeName
    }
    If ("ubuntu", "Red Hat" -contains $serverType)
    {
        $VM = Set-AzVMOperatingSystem -VM $vm -linux -ComputerName $vmName -Credential $vmCreds
    }
    Else
    {
        $VM = Set-AzVMOperatingSystem -VM $vm -Windows -ComputerName $vmName -Credential $vmCreds -ProvisionVMAgent -enableautoupdate $false
    }

    $VM = Set-AzVMSourceImage -VM $VM -PublisherName $vmPubName -Offer $vmOfferName -Skus $vmSKUName -Version "latest"
#endregion

#region Adding the NIC to the Config
    Write-host
    If ($setStaticIP)
    {
        If ($useAcceleratedNetworking)
        {
            write-host "Creating NIC $vmNicName with Static IP Address $VMIPAddress..." -ForegroundColor Green
            $vmNic = New-AzNetworkInterface -Name $vmNicName -ResourceGroupName $VMRGName -Location $vmRegionName -SubnetId $vmSubnet.Id -NetworkSecurityGroupId $vmNSG.id -PrivateIpAddress $VMIPAddress -EnableAcceleratedNetworking
        }
        Else
        {
            write-host "Creating NIC $vmNicName with Static IP Address $VMIPAddress..." -ForegroundColor Green
            $vmNic = New-AzNetworkInterface -Name $vmNicName -ResourceGroupName $VMRGName -Location $vmRegionName -SubnetId $vmSubnet.Id -NetworkSecurityGroupId $vmNSG.id -PrivateIpAddress $VMIPAddress
        }
    }
    Else
    {
        If ($useAcceleratedNetworking)
        {
            write-host "Creating NIC: $vmNicName with Dynamic IP Address..." -ForegroundColor Green
            $vmNic = New-AzNetworkInterface -Name $vmNicName -ResourceGroupName $VMRGName -Location $vmRegionName -SubnetId $vmSubnet.Id -NetworkSecurityGroupId $vmNSG.id -EnableAcceleratedNetworking
        }
        Else
        {
            write-host "Creating NIC: $vmNicName with Dynamic IP Address..." -ForegroundColor Green
            $vmNic = New-AzNetworkInterface -Name $vmNicName -ResourceGroupName $VMRGName -Location $vmRegionName -SubnetId $vmSubnet.Id -NetworkSecurityGroupId $vmNSG.id
        }
    }
    write-host "Adding $vmNicName to VM Config..." -ForegroundColor Green
    $VM = Add-AzVMNetworkInterface -VM $VM -Id $vmNic.Id
    write-host "Setting $vmNicName as Primary Interface" -ForegroundColor Green
    $VM.NetworkProfile.NetworkInterfaces.Item(0).Primary = $true
#endregion

#region Set up OS Disk
    $vmOSDiskName = $VMName+"_OSDisk.vhd"
    write-host
    If ($useManagedDisks)
    {
        $VM = Set-AZVMOSDisk -VM $VM -Name $vmOSDiskName -CreateOption fromImage
    }
    Else
    {
        $i = 0
        $vhdContainerName = "vhds"
        $vhdContainer = Get-AZStorageContainer -Name $vhdContainerName -Context $vmSA.context -ErrorAction Ignore
        while (-not($vhdContainer -eq $null))
        {
            $i += 1
            $vhdContainer = $null
            $vhdContainerName = "vhds" + "{0:d2}" -f $i
            $vhdContainer = Get-AZStorageContainer -name $vhdContainerName -Context $vmSA.context -ErrorAction Ignore
        }
        write-host "Creating Container $vhdContainerName in the $vmSAName Storage Account..." -foregroundcolor Green
        $vhdContainer = New-AZStorageContainer -name $vhdContainerName -Context $vmSA.context

        write-host "Creating OS Disk: $vmOSDiskName in the $vhdContainerName Container..." -ForegroundColor Green
        $vmOSDiskUri = $vmSA.PrimaryEndpoints.Blob.ToString() + $vhdContainerName + "/" + $vmOSDiskName
        $VM = Set-AzVMOSDisk -VM $VM -Name $vmOSDiskName -VhdUri $vmOSDiskUri -CreateOption fromImage
    }
#endregion

#region Set Boot Diagnostics Storage Account for VM
    If ($useBootDiags)
    {
        Write-host
        write-host "Setting Boot Diagnostic Storage Account:  $vmDiagsSAName" -ForegroundColor Green
        $VM = Set-AzVMBootDiagnostic -vm $VM -ResourceGroupName $vmDiagsSA.ResourceGroupName -StorageAccountName $vmDiagsSA.StorageAccountName -Enable
    }
#endregion

#region Create the VM
    write-host
    write-host "Creating VM: $VMName..." -ForegroundColor Green
    New-AzVM -ResourceGroupName $VMRGName -Location $vmRegionName -VM $VM
    write-host "$VMName Creation Complete" -foregroundcolor DarkCyan
    $VM = Get-AzVM -ResourceGroupName $VMRGName -Name $VMName
#endregion

#region Add Data disks
    write-host
    If ("ubuntu", "Red Hat" -notcontains $serverType)
    {
        write-host "Would you like to add data disks to this VM?" -ForegroundColor DarkCyan
        if (FCN_PromptYorN)
        {                                                                            
            write-host
            $ExistingNoOfDisks = ($VM.StorageProfile.DataDisks.Count)
            write-host "$VMName currently has $ExistingNoOfDisks data disks." -foregroundcolor DarkCyan
            Write-host "How many disks would you like to add?" -ForegroundColor DarkCyan
            $NoOfDisks = FCN_PromptNumberBetweenXandY 1 ($VMSize.MaxDataDiskCount - $ExistingNoOfDisks)
            $SizeList = 128, 256, 512, 1024, 2048, 3072, 4096, 5120, 6144, 7168, 8192
            write-host "What size disks would you like to add?" -ForegroundColor DarkCyan
            FCN_DisplayListWithNumbers $SizeList
            $SizeofDisk = $sizeList[(FCN_PromptNumberBetweenXandY 1 $sizelist.count) -1]
            write-host "Adding $noOfDisks data disks, sized $sizeofDisk GB each, to $vmName" -ForegroundColor Green
            #For ($i=$ExistingNoOfDisks + 1; $i -le ($ExistingNoOfDisks + $NoOfDisks); $i++)
            $i = 1..($NoOfDisks)
            Foreach ($diskNumber in $i) 
            {
                $No = "{0:D2}" -f $diskNumber
                $DiskName = $VMName + "_Disk" + $No.Tostring()
                $VhdURI = "https://" + $SAname + ".blob.core.windows.net/" + $vmContainerName + "/" + $DiskName + ".vhd"
                $Lun = $diskNumber - 1
                If ($useManagedDisks)
                {
                    $diskConfig = New-AzDiskConfig -SkuName $vmStorageSKU -Location $vmRegionName -CreateOption Empty -DiskSizeGB $sizeofDisk
                    $dataDisk1 = New-AzDisk -DiskName $diskName -Disk $diskConfig -ResourceGroupName $VMRGName
                    $vm = Add-AzVMDataDisk -VM $vm -Name $diskName -CreateOption Attach -ManagedDiskId $dataDisk1.Id -Lun $lun
                }
                Else
                {
                    Add-AzVMDataDisk -VM $VM -name $DiskName -VhdUri $VhdURI -Caching None -Lun $Lun -DiskSizeInGB $SizeofDisk -CreateOption Empty
                }
            }
            Update-AzVM -VM $VM -ResourceGroupName $VMRGName
            write-host "$NoOfDisks Data Disks added to $VMName" -ForegroundColor DarkCyan
        }
    
    }
#endregion

#region Encrypt the VM
    write-host
    If ("ubuntu", "Red Hat" -notcontains $serverType)
    {
        write-host "Would you like to encrypt the drives of this VM? with Bitlocker" -ForegroundColor DarkCyan
        write-host "This will reboot the VM" -ForegroundColor Gray
        if (FCN_PromptYorN)
        {
            [array]$keyVaultNameList = (Get-AzKeyVault).VaultName | sort
            If ($keyVaultNameList.count -eq 0)
            {
                write-host "No KeyVault currently Exists.  A KeyVault must be created to encrypt the machine." -ForegroundColor Red
                write-host "What is the Name of the Key Vault you would like to create?" -ForegroundColor Magenta
                $keyVaultName = read-host
                write-host "In what Resource Group would you like to place the Key Vault?" -ForegroundColor Magenta
                $keyVaultRGName = FCN_PromptExisting $RGNameList "Resource Group"
                write-host "Im What Region WOuld you like to place the Key Vault?"
                $keyVaultRegionName = FCN_PromptExisting $RegionNameList "Azure Region"
                write-host "What would you like to name the Bitlocker Key in this new KeyVault"
                $keyName = read-host
                write-host "Creating Key Vault named $keyVaultName" -ForegroundColor Green
                $keyVault = New-AzKeyVault -Name $keyVaultName -ResourceGroupName $keyVaultRGName -Location $keyVaultRegionName
                write-host "Creating New Key Named $keyName in $keyVaultName" -ForegroundColor Green
                $key = Add-AzKeyVaultKey -VaultName $keyVaultName -Name $KeyName -Destination Software
            }
            Else
            {
                $keyVaultNameList += "Create New Key Vault"
                write-host "Which Key Vault Would you like to use?" -ForeGroundColor DarkCyan
                FCN_DisplayListWithNumbers $keyVaultNameList
                $s = FCN_PromptNumberBetweenXandY 1 ($keyVaultNameList.count)
                if ($s -eq $keyVaultNameList.count)
                {
                    write-host "What is the Name of the Key Vault you would like to create?" -ForegroundColor Magenta
                    $keyVaultName = FCN_PromptNew ($keyVaultNameList).VaultName "Key Vault"
                    write-host "In what Resource Group would you like to place the Key Vault?" -ForegroundColor Magenta
                    $keyVaultRGName = FCN_PromptExisting $RGNameList "Resource Group"
                    write-host "Im What Region WOuld you like to place the Key Vault?"
                    $keyVaultRegionName = FCN_PromptExisting $RegionNameList "Azure Region"
                    write-host "What would you like to name the Bitlocker Key in this new KeyVault"
                    $keyName = read-host
                    write-host "Creating Key Vault named $keyVaultName" -ForegroundColor Green
                    $keyVault = New-AzKeyVault -Name $keyVaultName -ResourceGroupName $keyVaultRGName
                    write-host "Creating New Key Named $keyName in $keyVaultName" -ForegroundColor Green
                    $key = Add-AzKeyVaultKey -VaultName $keyVaultName -Name $keyName -Destination Software
                }
                Else
                {
                    $keyVaultName = $keyvaultNameList[$s - 1]
                    $keyVault = Get-AZKeyVault -name $keyVaultName
                    [array]$keyNameList = (Get-AZKeyVaultKey -VaultName $keyVault.VaultName).Name
                    $keyNameList += "Create New Key"
                    write-host "Which key would you like to use to encrypt the VMs?" -ForegroundColor Magenta
                    FCN_DisplayListWithNumbers $keyNameList
                    $s = FCN_PromptNumberBetweenXandY 1 ($keyNamelist.count)
                    If ($s -eq $keyNameList.count)
                    {
                        write-host "What would you like to name the Bitlocker Key in this KeyVault"
                        $keyName = FCN_PromptNew $keyNameList "Key Name"
                        $key = Add-AzKeyVaultKey -VaultName $keyVault.VaultName -Name $keyName -Destination Software
                    }
                    Else
                    {
                        $keyName = $keyNameList[$s - 1]
                        $key = Get-AZKeyVaultKey -VaultName $keyVault.VaultName -Name $keyName
                    }
                }
            }
            If ($keyVault.EnabledForDiskEncryption -eq $False)
            {
                write-host "The Key Vault $keyVaultName is not enabled for Disk Encryption." -ForegroundColor Red
                write-host "Enabling Key Vault $keyVaultName for Disk Encyrption." -ForegroundColor Green
                Set-AzKeyVaultAccessPolicy -VaultName $keyVault.VaultName -ResourceGroupName $keyVault.ResourceGroupName -EnabledForDiskEncryption
            }
            $diskEncryptionKeyVaultUrl = $keyVault.VaultUri
            $keyVaultResourceId = $keyVault.ResourceId
            $keyEncryptionKeyUrl = $key.Key.kid
            write-host "Encrypting Drives..." -foregroundcolor Green
            $job = Set-AzVMDiskEncryptionExtension -ResourceGroupName $vmRGName -VMName $vmName -DiskEncryptionKeyVaultUrl $keyVault.VaultUri -DiskEncryptionKeyVaultId $keyVault.ResourceId -KeyEncryptionKeyUrl (Get-AzKeyVaultKey -VaultName $keyVault.VaultName -Name $key.Name).Key.kid -KeyEncryptionKeyVaultId $keyVault.ResourceId -force
            If ($job.IsSuccessStatusCode -eq $True -and (Get-AzVMDiskEncryptionStatus -VMName $vmName -ResourceGroupName $vmRGName).OSVolumeENcrypted -eq "Encrypted")
            {
                write-host "$VMName is now Encrypted" -ForegroundColor DarkCyan
            }
            Else
            {
                write-host
                write-host "An Error occured Encrypting the VM.  Please investigate" -ForegroundColor Red
            }
        }
    }

#endregion

#region Backup the VM
    write-host
    write-host "Would you like to backup this VM?" -ForegroundColor DarkCyan
    write-host "This will reboot the VM" -ForegroundColor Gray
    if (FCN_PromptYorN)
    {
        $keyVaultPermissionsToKeys = ($keyvault.accesspolicies | where-object {$_.displayname -match "Backup Management Service"}).PermissionToKeys
        If (($keyVAultPermissionsToKeys -notcontains "Get") -or ($keyVaultPermissionsToKeys -notcontains "List") -or ($KeyVaultPermissionsToKeys -notcontains "Backup"))
        {
            $backupServicePrincipal = Get-AzADServicePrincipal -DisplayNameBeginsWith "Backup Management Service"
            write-host "The Backup Management Serivce does not have the proper permissions to the $keyVaultName Key Vault where the VM Key are stored." -ForegroundColor Red
            write-host "The Backup Management Servcice will be given 'Get', 'List' and 'Backup' permissions to $keyVaultName"
            Set-AZKeyVaultAccessPolicy -VaultName $keyVaultName -ResourceGroupName $keyVaultRGName -ServicePrincipalName $backupServicePrincipal.ApplicationId -PermissionsToKeys Get, List, Backup -PermissionsToSecrets Get, List, Backup -PermissionsToCertificates Get, List, Backup
        }
        [array]$recoveryVaultNameList = (Get-AZRecoveryServicesVault | where-object {$_.Location -eq $vmRegion.location}).Name
        If ($recoveryVaultNameList.count -eq 0)
        {
            write-host "There are No Recovery Services Vaults in the $VMRegionName Region where the VM exists" -ForegroundColor Red
            write-host "We will create a new Recovery Services Vault." -ForegroundColor DarkCyan
            write-host "What would you like to name the new Recovery Services Vault" -ForegroundColor DarkCyan
            $recoveryVaultName = FCN_PromptNew $recoveryVaultNameList "Recovery Services Vault"
            write-host "In which Resource Group would you like to create this Recovery Services Vault?"
            $recoveryVaultRGName = FCN_PromptExisting $RGNameList "Resource Group"
            $recoveryVaultRegionName = $vmRegion.location
            $recoveryVault = New-AZRecoveryServicesVault -Name $recoveryVaultName -ResourceGroupName $recoveryVaultRGName -Location $recoveryVaultRegionName
            $recoveryVaultID = $recoveryVault.id

            write-host "A New Backup Policy will be createdusing the default retention and schedule policies"
            write-host "What would you like to name the new Backup Policy?"
            $backupPolicyList = Get-AzRecoveryServicesBackupProtectionPolicy -VaultId $recoveryVaultID
            $backupPolicyName = FCN_PromptNew $backupPolicyList "Backup Policy"
            $SchPol = Get-AzRecoveryServicesBackupSchedulePolicyObject -WorkloadType "AzureVM" 
            $SchPol.ScheduleRunTimes.Clear()
            $Dt = Get-Date
            $SchPol.ScheduleRunTimes.Add($Dt.ToUniversalTime())
            $RetPol = Get-AzRecoveryServicesBackupRetentionPolicyObject -WorkloadType "AzureVM" 
            $RetPol.DailySchedule.DurationCountInDays = 365
            $backupPolicy = New-AzRecoveryServicesBackupProtectionPolicy -Name $backupPolicyName -WorkloadType AzureVM -RetentionPolicy $RetPol -SchedulePolicy $SchPol
            $backupPolicyID = $backupPolicy.Id

        }
        Else
        {
            $recoveryVaultNameList += "Create New Recovery Vault"
            write-host "In which Recovery Services Vault would you like to backup the VM?" -ForegroundColor DarkCyan
            FCN_DisplayListWithNumbers $recoveryVaultNameList
            $s = FCN_PromptNumberBetweenXandY 1 $recoveryVaultNameList.count
            If ($s -eq $recoveryVaultNameList.count)
            {
                write-host "What would you like to name the new Recovery Services Vault" -ForegroundColor DarkCyan
                $recoveryVaultName = FCN_PromptNew $recoveryVaultNameList "Recovery Services Vault"
                write-host "In which Resource Group would you like to create this Recovery Services Vault?"
                $recoveryVaultRGName = FCN_PromptExisting $RGNameList "Resource Group"
                $recoveryVaultRegionName = $vmRegion.location
                $recoveryVault = New-AZRecoveryServicesVault -Name $recoveryVaultName -ResourceGroupName $recoveryVaultRGName -Location $recoveryVaultRegionName
                $recoveryVaultID = $recoveryVault.id
            }
            Else
            {
                $recoveryVaultName = $recoveryVaultNameList[$s - 1]
                $recoveryVault = Get-AZRecoveryServicesVault -name $recoveryVaultName
                $recoveryVaultID = $recoveryVault.ID
            }    
            $backupPolicyNameList = (Get-AZRecoveryServicesBackupProtectionPolicy -VaultId $recoveryVault.ID).Name
            write-host "Which Backup Policy would you like to use to backup the VM?" -ForegroundColor DarkCyan
            FCN_DisplayListWithNumbers $backupPolicyNameList
            $backupPolicyName = $backupPolicyNameList[(FCN_PromptNumberBetweenXandY 1 $backupPolicyNameList.count) - 1]
            $backupPolicy = Get-AZRecoveryServicesBackupProtectionPolicy -Name $backupPolicyName -VaultId $recoveryVaultID
            $backupPolicyID = $backupPolicy.Id
        }
        write-host "Configuring VM Backups..." -ForegroundColor Green
        $job = Enable-AzRecoveryServicesBackupProtection -Policy $backupPolicy -Name $vmName -ResourceGroupName $VMRGName -VaultId $recoveryVaultID
        If ($job.status -eq "Completed")
        {
            write-host "$VMName is now configured for backup" -ForegroundColor DarkCyan
            write-host
            write-host "Would you like to run the first backup job now" -ForegroundColor DarkCyan
            If (FCN_PromptYorN)
            {
                write-host "Starting 1st Backup of $VMName..." -ForegroundColor Green
                $namedContainer = Get-AzRecoveryServicesBackupContainer -ContainerType "AzureVM" -Status "Registered" -FriendlyName $VMName -VaultId $recoveryVaultID
                $item = Get-AzRecoveryServicesBackupItem -Container $namedContainer -WorkloadType "AzureVM" -VaultId $recoverVaultID
                $job = Backup-AzRecoveryServicesBackupItem -Item $item -VaultId $recoveryVaultID
            
                If ($job.status -eq "Failed")
                {
                    write-host "The job failed.  Please check the Azure Portal." -foregroundcolor -red
                }
                Else
                {
                    write-host "First Backup has started" -ForegroundColor DarkCyan
                }
           
             }
        }
        Else
        {
            write-host "There was a problem Enabling Backup for the VM, please investigate" -ForegroundColor Red
        }
    }
#endregion

write-host
write-host "Script Complete" -ForegroundColor DarkCyan