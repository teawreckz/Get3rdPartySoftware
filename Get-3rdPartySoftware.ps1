<#
.SYNOPSIS
    Download 3rd party update files
.DESCRIPTION
    Parses third party updates sites for download links, then downloads them to their folder
.PARAMETER 
    NONE
.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -file "Get-3rdPartySoftware.ps1"
.NOTES
    Script name: Get-3rdPartySoftware.ps1
    Version:     2.0
    Author:      Richard Tracy
    DateCreated: 2016-02-11
    LastUpdate:  2018-10-25
    Alternate Source: https://michaelspice.net/windows/windows-software
#>

#==================================================
# FUNCTIONS
#==================================================
function Test-IsISE {
# try...catch accounts for:
# Set-StrictMode -Version latest
    try {    
        return $psISE -ne $null;
    }
    catch {
        return $false;
    }
}

Function logstamp {
    $now=get-Date
    $yr=$now.Year.ToString()
    $mo=$now.Month.ToString()
    $dy=$now.Day.ToString()
    $hr=$now.Hour.ToString()
    $mi=$now.Minute.ToString()
    if ($mo.length -lt 2) {
    $mo="0"+$mo #pad single digit months with leading zero
    }
    if ($dy.length -lt 2) {
    $dy ="0"+$dy #pad single digit day with leading zero
    }
    if ($hr.length -lt 2) {
    $hr ="0"+$hr #pad single digit hour with leading zero
    }
    if ($mi.length -lt 2) {
    $mi ="0"+$mi #pad single digit minute with leading zero
    }

    write-output $yr$mo$dy$hr$mi
}

Function Write-Log{
   Param ([string]$logstring)
   Add-content $Logfile -value $logstring -Force
}


function Get-HrefMatches{
    param(
    ## The filename to parse
    [Parameter(Mandatory = $true)]
    [string] $content,
    
    ## The Regular Expression pattern with which to filter
    ## the returned URLs
    [string] $Pattern = "<\s*a\s*[^>]*?href\s*=\s*[`"']*([^`"'>]+)[^>]*?>"
)

    $returnMatches = new-object System.Collections.ArrayList

    ## Match the regular expression against the content, and
    ## add all trimmed matches to our return list
    $resultingMatches = [Regex]::Matches($content, $Pattern, "IgnoreCase")
    foreach($match in $resultingMatches)
    {
        $cleanedMatch = $match.Groups[1].Value.Trim()
        [void] $returnMatches.Add($cleanedMatch)
    }

    $returnMatches
}

Function Get-Hyperlinks {
    param(
    [Parameter(Mandatory = $true)]
    [string] $content,
    [string] $Pattern = "<A[^>]*?HREF\s*=\s*""([^""]+)""[^>]*?>([\s\S]*?)<\/A>"
    )
    $resultingMatches = [Regex]::Matches($content, $Pattern, "IgnoreCase")
    
    $returnMatches = @()
    foreach($match in $resultingMatches){
        $LinkObjects = New-Object -TypeName PSObject
        $LinkObjects | Add-Member -Type NoteProperty `
            -Name Text -Value $match.Groups[2].Value.Trim()
        $LinkObjects | Add-Member -Type NoteProperty `
            -Name Href -Value $match.Groups[1].Value.Trim()
        
        $returnMatches += $LinkObjects
    }
    $returnMatches
}


Function Get-MSIInfo{
    param(
    [parameter(Mandatory=$true)]
    [IO.FileInfo]$Path,
    [parameter(Mandatory=$true)]
    [ValidateSet("ProductCode","ProductVersion","ProductName")]
    [string]$Property
    )
    try {
        $WindowsInstaller = New-Object -ComObject WindowsInstaller.Installer
        $MSIDatabase = $WindowsInstaller.GetType().InvokeMember("OpenDatabase","InvokeMethod",$Null,$WindowsInstaller,@($Path.FullName,0))
        $Query = "SELECT Value FROM Property WHERE Property = '$($Property)'"
        $View = $MSIDatabase.GetType().InvokeMember("OpenView","InvokeMethod",$null,$MSIDatabase,($Query))
        $View.GetType().InvokeMember("Execute", "InvokeMethod", $null, $View, $null)
        $Record = $View.GetType().InvokeMember("Fetch","InvokeMethod",$null,$View,$null)
        $Value = $Record.GetType().InvokeMember("StringData","GetProperty",$null,$Record,1)
        return $Value
        Remove-Variable $WindowsInstaller
    } 
    catch {
        Write-Output $_.Exception.Message
    }

}

Function Wait-FileUnlock{
    Param(
        [Parameter()]
        [IO.FileInfo]$File,
        [int]$SleepInterval=500
    )
    while(1){
        try{
           $fs=$file.Open('open','read', 'Read')
           $fs.Close()
            Write-Verbose "$file not open"
           return
           }
        catch{
           Start-Sleep -Milliseconds $SleepInterval
           Write-Verbose '-'
        }
	}
}

function IsFileLocked([string]$filePath){
    Rename-Item $filePath $filePath -ErrorVariable errs -ErrorAction SilentlyContinue
    return ($errs.Count -ne 0)
}

function Download-FileProgress($url, $targetFile){
   $uri = New-Object "System.Uri" "$url"
   $request = [System.Net.HttpWebRequest]::Create($uri)
   $request.set_Timeout(15000) #15 second timeout
   $response = $request.GetResponse()
   $totalLength = [System.Math]::Floor($response.get_ContentLength()/1024)
   $responseStream = $response.GetResponseStream()
   $targetStream = New-Object -TypeName System.IO.FileStream -ArgumentList $targetFile, Create
   $buffer = new-object byte[] 10KB
   $count = $responseStream.Read($buffer,0,$buffer.length)
   $downloadedBytes = $count
   while ($count -gt 0)
   {
       $targetStream.Write($buffer, 0, $count)
       $count = $responseStream.Read($buffer,0,$buffer.length)
       $downloadedBytes = $downloadedBytes + $count
       Write-Progress -activity "Downloading file '$($url.split('/') | Select -Last 1)'" -status "Downloaded ($([System.Math]::Floor($downloadedBytes/1024))K of $($totalLength)K): " -PercentComplete ((([System.Math]::Floor($downloadedBytes/1024)) / $totalLength)  * 100)
   }
   Write-Progress -activity "Finished downloading file '$($url.split('/') | Select -Last 1)'"
   $targetStream.Flush()
   $targetStream.Close()
   $targetStream.Dispose()
   $responseStream.Dispose()
}

Function Get-FileProperties{
    Param([io.fileinfo]$FilePath)
    $objFileProps = Get-item $filepath | Get-ItemProperty | select *
 
    #Get required Comments extended attribute
    $objShell = New-object -ComObject shell.Application
    $objShellFolder = $objShell.NameSpace((get-item $filepath).Directory.FullName)
    $objShellFile = $objShellFolder.ParseName((get-item $filepath).Name)
 
    $strComments = $objShellfolder.GetDetailsOf($objshellfile,24)
    $Version = [version]($strComments | Select-string -allmatches '(\d{1,4}\.){3}(\d{1,4})').matches.Value
    $objShellFile = $null
    $objShellFolder = $null
    $objShell = $null
    Add-Member -InputObject $objFileProps -MemberType NoteProperty -Name Version -Value $Version
    Return $objFileProps
}

function Get-FtpDir ($url,$credentials) {
    $request = [Net.WebRequest]::Create($url)
    $request.Method = [System.Net.WebRequestMethods+FTP]::ListDirectory
    if ($credentials) { $request.Credentials = $credentials }
    $response = $request.GetResponse()
    $reader = New-Object IO.StreamReader $response.GetResponseStream() 
	$reader.ReadToEnd()
	$reader.Close()
	$response.Close()
}
##*=============================================
##* VARIABLE DECLARATION
##*=============================================

## Variables: Script Name and Script Paths
[string]$scriptPath = $MyInvocation.MyCommand.Definition
If(Test-IsISE){$scriptPath = "C:\GitHub\Get3rdPartySoftware\Get-3rdPartySoftware.ps1"}
[string]$scriptName = [IO.Path]::GetFileNameWithoutExtension($scriptPath)
[string]$scriptFileName = Split-Path -Path $scriptPath -Leaf
[string]$scriptRoot = Split-Path -Path $scriptPath -Parent
[string]$invokingScript = (Get-Variable -Name 'MyInvocation').Value.ScriptName

#  Get the invoking script directory
If ($invokingScript) {
	#  If this script was invoked by another script
	[string]$scriptParentPath = Split-Path -Path $invokingScript -Parent
}
Else {
	#  If this script was not invoked by another script, fall back to the directory one level above this script
	[string]$scriptParentPath = (Get-Item -LiteralPath $scriptRoot).Parent.FullName
}

# BUILD FOLDER STRUCTURE
#=======================================================

[string]$3rdPartyFolder = Join-Path -Path $scriptRoot -ChildPath 'Software'
#Remove-Item $3rdPartyFolder -Recurse -Force
New-Item $3rdPartyFolder -type directory -ErrorAction SilentlyContinue | Out-Null


# JAVA 8 - DOWNLOAD
#==================================================
Function Get-Java8 {
    param(
	    [parameter(Mandatory=$true)]
        [string]$RootPath,
        [parameter(Mandatory=$true)]
        [string]$FolderPath,
        [parameter(Mandatory=$false)]
        [ValidateSet('x86', 'x64', 'Both')]
        [string]$Arch = 'Both',
        [switch]$Overwrite = $false,
        [switch]$ReturnDetails 
	)
    
    $SoftObject = @()
    $Publisher = "Oracle"
    $Product = "Java 8"
    $Language = 'en'
    $ProductType = 'jre'

    [string]$SourceURL = "http://www.java.com/$Language/download/manual.jsp"

    $DestinationPath = Join-Path -Path $RootPath -ChildPath $FolderPath
    If( !(Test-Path $DestinationPath)){
        New-Item $DestinationPath -type directory -ErrorAction SilentlyContinue | Out-Null
    }

    $content = Invoke-WebRequest $SourceURL
    start-sleep 3

    $javaTitle = $content.AllElements | Where outerHTML -like "*Version*" | Where innerHTML -like "*Update*" | Select -Last 1 -ExpandProperty outerText
    $parseVersion = $javaTitle.split("n ") | Select -Last 3 #Split after n in version
    $JavaMajor = $parseVersion[0]
    $JavaMinor = $parseVersion[2]
    $Version = "1." + $JavaMajor + ".0." + $JavaMinor
    $FileVersion = $parseVersion[0]+"u"+$parseVersion[2]
    $LogComment = "Java latest version is: [$JavaMajor Update $JavaMinor]" 
     Write-Host $LogComment -ForegroundColor Yellow | Write-Log -logstring $LogComment

    $javaFileSuffix = ""
 
    #Remove all folders and files except the latest if they exist
    Get-ChildItem -Path $DestinationPath -Exclude sites.exception | Where {$_.Name -notmatch $Version} | foreach ($_) {
        Remove-Item $_.fullname -Recurse -Force | Out-Null
        $LogComment = "Removed... :" + $_.fullname
            Write-Host $LogComment -ForegroundColor DarkMagenta | Write-Log -logstring $LogComment
    }
    #build Destination folder based on version
    New-Item -Path "$DestinationPath\$Version" -type directory -ErrorAction SilentlyContinue | Out-Null
 
 
    switch($Arch){
        'x86' {$DownloadLinks = $content.AllElements | Where innerHTML -eq "Windows Offline" | Select -ExpandProperty href | Select -First 1;
               $javaFileSuffix = "-windows-i586.exe","";
               $archLabel = 'x86',''}
               
        'x64' {$DownloadLinks = $content.AllElements | Where innerHTML -eq "Windows Offline (64-bit)" | Select -ExpandProperty href | Select -First 1;
               $javaFileSuffix = "-windows-x64.exe","";
               $archLabel = 'x64',''}

        'Both' {$DownloadLinks = $content.AllElements | Where innerHTML -like "Windows Offline*" | Select -ExpandProperty href | Select -First 2;
               $javaFileSuffix = "-windows-i586.exe","-windows-x64.exe";
               $archLabel = 'x86','x64'}
    }

 
    $i = 0

    Foreach ($link in $DownloadLinks){
        $LogComment = "Validating Download Link: $link"
          Write-Host $LogComment -ForegroundColor DarkYellow | Write-Log -logstring $LogComment
        
        If($javaFileSuffix -eq 1){$i = 0}
        $Filename = $ProductType + "-" + $JavaMajor + "u" + "$JavaMinor" + $javaFileSuffix[$i]
        #$destination = $DestinationPath + "\" + $Filename
        $destination = $DestinationPath + "\" + $Version + "\" + $Filename

        $ExtensionType = [System.IO.Path]::GetExtension($fileName)

        If ( (Test-Path $destination -ErrorAction SilentlyContinue) -and !$Overwrite){
            $LogComment = "$Filename is already downloaded"
                Write-Host $LogComment -ForegroundColor Gray | Write-Log -logstring $LogComment
        }
        Else{
            Try{
                $LogComment = "Attempting to download: $Filename"
                    Write-Host $LogComment -ForegroundColor DarkYellow | Write-Log -logstring $LogComment
                Download-FileProgress -url $link -targetFile $destination
                #$wc.DownloadFile($link, $destination) 
                $LogComment = "Succesfully downloaded Java $JavaMajor Update $JavaMinor ($($archLabel[$i])) to $destination"
                    Write-Host $LogComment -ForegroundColor Green | Write-Log -logstring $LogComment
            } 
            Catch {
                $LogComment = ("failed to download to: [{0}]" -f $destination)
                    Write-Host $LogComment -ForegroundColor Red | Write-Log -logstring $LogComment
            }
        }
        
        #build array of software for inventory
        $SoftObject += new-object psobject -property @{
            FilePath=$destination
            Version=$Version
            File=$Filename
            Publisher=$Publisher
            Product=$Product
            Arch=$archLabel[$i]
            Language=$Language
            FileType=$ExtensionType
            ProductType=$ProductType
        }

        $i++
    }
    If($ReturnDetails){
        return $SoftObject
    }

}


# Chrome (x86 & x64) - DOWNLOAD
#==================================================
Function Get-Chrome {
    param(
	    [parameter(Mandatory=$true)]
        [string]$RootPath,
        [parameter(Mandatory=$true)]
        [string]$FolderPath,
        [parameter(Mandatory=$false)]
        [ValidateSet('Enterprise (x86)', 'Enterprise (x64)', 'Enterprise (Both)','Standalone (x86)','Standalone (x64)','Standalone (Both)','All')]
        [string]$ArchType = 'All',
        [switch]$Overwrite = $false,
        [switch]$ReturnDetails 
	)

    $SoftObject = @()
    $Publisher = "Google"
    $Product = "Chrome"

    [string]$SourceURL = "https://www.whatismybrowser.com/guides/the-latest-version/chrome"
    [string]$DownloadURL = "https://dl.google.com/dl/chrome/install"

    $DestinationPath = Join-Path -Path $RootPath -ChildPath $FolderPath
    If( !(Test-Path $DestinationPath)){
        New-Item $DestinationPath -type directory -ErrorAction SilentlyContinue | Out-Null
    }

    $content = Invoke-WebRequest $SourceURL

    $GetVersion = ($content.AllElements | Select -ExpandProperty outerText  | Select-String '^(\d+\.)(\d+\.)(\d+\.)(\d+)' | Select -first 1).ToString()
    $Version = $GetVersion.Trim()
    $LogComment = "Chromes latest stable version is: [$Version]"
     Write-Host $LogComment -ForegroundColor Yellow | Write-Log -logstring $LogComment

    #Remove all folders and files except the latest if they exist
    Get-ChildItem -Path $DestinationPath -Exclude disableupdates.bat | Where {$_.Name -notmatch $Version} | foreach ($_) {
        Remove-Item $_.fullname -Recurse -Force | Out-Null
        $LogComment = "Removed... :" + $_.fullname
            Write-Host $LogComment -ForegroundColor DarkMagenta | Write-Log -logstring $LogComment
    }
    #build Destination folder based on version
    New-Item -Path "$DestinationPath\$Version" -type directory -ErrorAction SilentlyContinue | Out-Null

    switch($ArchType){
        'Enterprise (x86)' {$DownloadLinks = "$DownloadURL/googlechromestandaloneenterprise.msi"}
        'Enterprise (x64)' {$DownloadLinks = "$DownloadURL/googlechromestandaloneenterprise64.msi"}

        'Enterprise (Both)' {$DownloadLinks = "$DownloadURL/googlechromestandaloneenterprise64.msi",
                                                "$DownloadURL/googlechromestandaloneenterprise.msi"}

        'Standalone (x86)' {$DownloadLinks = "$DownloadURL/ChromeStandaloneSetup.exei"}
        'Standalone (x64)' {$DownloadLinks = "$DownloadURL/ChromeStandaloneSetup64.exe"}

        'Standalone (Both)' {$DownloadLinks = "$DownloadURL/ChromeStandaloneSetup64.exe",
                                                "$DownloadURL/ChromeStandaloneSetup.exe"}

        'All' {$DownloadLinks = "$DownloadURL/googlechromestandaloneenterprise64.msi",
                                "$DownloadURL/googlechromestandaloneenterprise.msi",
                                "$DownloadURL/ChromeStandaloneSetup64.exe",
                                "$DownloadURL/ChromeStandaloneSetup.exe"
                }
    }

    Foreach ($source in $DownloadLinks){
        $LogComment = "Validating Download Link: $source"
         Write-Host $LogComment -ForegroundColor DarkYellow | Write-Log -logstring $LogComment
        $DownloadLink = $source
        $Filename = $DownloadLink | Split-Path -Leaf
        $destination = $DestinationPath + "\" + $Version + "\" + $Filename
        
        #find what arch the file is based on the integer 64
        $pattern = "\d{2}"
        $Filename -match $pattern | Out-Null

        #if match is found, set label
        If($matches){
            $ArchLabel = "x64"
        }Else{
            $ArchLabel = "x86"
        }
        
        # Determine if its enterprise download (based on file name)
        $pattern = "(?<text>.*enterprise*)"
        $Filename -match $pattern | Out-Null
        If($matches.text){
            $ProductType = "Enterprise"
        }Else{
            $ProductType = "Standalone"
        }

        #clear matches
        $matches = $null

        $ExtensionType = [System.IO.Path]::GetExtension($fileName)
           
        If ( (Test-Path "$destination" -ErrorAction SilentlyContinue) -and !$Overwrite){
            $LogComment = "$Filename is already downloaded"
             Write-Host $LogComment -ForegroundColor Gray | Write-Log -logstring $LogComment
        }
        Else{
            Try{
                Download-FileProgress -url $DownloadLink -targetFile $destination
                $LogComment = ("Succesfully downloaded: " + $Filename + " ($ArchLabel) to $destination")
                 Write-Host $LogComment -ForegroundColor Green | Write-Log -logstring $LogComment   
            } 
            Catch {
                $LogComment = ("failed to download to: [{0}]" -f $destination)
                 Write-Host $LogComment -ForegroundColor Red | Write-Log -logstring $LogComment
            }
        }

        #build array of software for inventory
        $SoftObject += new-object psobject -property @{
            FilePath=$destination
            Version=$Version
            File=$Filename
            Publisher=$Publisher
            Product=$Product
            Arch=$ArchLabel
            Language=''
            FileType=$ExtensionType
            ProductType=$ProductType
        }

    }

    If($ReturnDetails){
        return $SoftObject
    }

}


# Firefox (x86 & x64) - DOWNLOAD
#==================================================
Function Get-Firefox {
    param(
	    [parameter(Mandatory=$true)]
        [string]$RootPath,
        [parameter(Mandatory=$true)]
        [string]$FolderPath,
        [parameter(Mandatory=$false)]
        [ValidateSet('x86', 'x64', 'Both')]
        [string]$Arch = 'Both',
        [switch]$Overwrite = $false,
        [switch]$ReturnDetails 
	)

    $SoftObject = @()
    $Publisher = "Mozilla"
    $Product = "Firefox"
    $Language = 'en-US'

    [string]$SourceURL = "https://product-details.mozilla.org/1.0/firefox_versions.json"
    [string]$DownloadURL = "https://www.mozilla.org/$Language/firefox/all/"

    $DestinationPath = Join-Path -Path $RootPath -ChildPath $FolderPath
    If( !(Test-Path $DestinationPath)){
        New-Item $DestinationPath -type directory -ErrorAction SilentlyContinue | Out-Null
    }

    $versions_json = $SourceURL
    $versions_file = "$env:temp\firefox_versions.json"
    $wc.DownloadFile($versions_json, $versions_file)
    $convertjson = (Get-Content -Path $versions_file) | ConvertFrom-Json
    $Version = $convertjson.LATEST_FIREFOX_VERSION

    $LogComment = "Firefox latest version is: [$Version]"
     Write-Host $LogComment -ForegroundColor Yellow | Write-Log -logstring $LogComment

    $content = Invoke-WebRequest $DownloadURL
    start-sleep 3

    $firefoxInfo = $content.AllElements | Where id -eq "en-US" | Select -ExpandProperty outerHTML

    #Remove all folders and files except the latest if they exist
    Get-ChildItem -Path $DestinationPath -Exclude Import-CertsinFirefox.ps1,Configs | Where {$_.Name -notmatch $Version} | foreach ($_) {
        Remove-Item $_.fullname -Recurse -Force | Out-Null
        $LogComment = "Removed... :" + $_.fullname
            Write-Host $LogComment -ForegroundColor DarkMagenta | Write-Log -logstring $LogComment
    }
    #build Destination folder based on version
    New-Item -Path "$DestinationPath\$Version" -type directory -ErrorAction SilentlyContinue | Out-Null

    switch($Arch){
        'x86' {$DownloadLinks = Get-HrefMatches -content $firefoxInfo | Where {$_ -like "*win*"} | Select -Last 1}
        'x64' {$DownloadLinks = Get-HrefMatches -content $firefoxInfo | Where {$_ -like "*win64*"} | Select -Last 1}
        'Both' {$DownloadLinks = Get-HrefMatches -content $firefoxInfo | Where {$_ -like "*win*"} | Select -Last 2}
    }

    Foreach ($link in $DownloadLinks){
        $LogComment = "Validating Download Link: $link"
         Write-Host $LogComment -ForegroundColor DarkYellow | Write-Log -logstring $LogComment
        $DownloadLink = $link

        If ($link -like "*win64*"){
            $Filename = "Firefox Setup " + $Version + " (x64).exe"
            $ArchLabel = "x64"
        }
        Else{
            $Filename = "Firefox Setup " + $Version + ".exe"
            $ArchLabel = "x86"
        }

        $ExtensionType = [System.IO.Path]::GetExtension($FileName)

        $destination = $DestinationPath + "\" + $Version + "\" + $Filename

        If ( (Test-Path "$destination" -ErrorAction SilentlyContinue) -and !$Overwrite){
            $LogComment = "$Filename is already downloaded"
             Write-Host $LogComment -ForegroundColor Gray | Write-Log -logstring $LogComment
        }
        Else{
            Try{
                #$wc.DownloadFile($DownloadLink, $destination)
                Download-FileProgress -url $DownloadLink -targetFile $destination
                $LogComment = ("Succesfully downloaded: " + $Filename + " to $destination")
                 Write-Host $LogComment -ForegroundColor Green | Write-Log -logstring $LogComment   
            } 
            Catch {
                $LogComment = ("failed to download to: [{0}]" -f $destination)
                 Write-Host $LogComment -ForegroundColor Red | Write-Log -logstring $LogComment
            }
        }

        #build array of software for inventory
        $SoftObject += new-object psobject -property @{
            FilePath=$destination
            Version=$Version
            File=$Filename
            Publisher=$Publisher
            Product=$Product
            Arch=$ArchLabel
            Language=$Language
            FileType=$ExtensionType
            ProductType=$ProductType
        }

    }

    If($ReturnDetails){
        return $SoftObject
    }
}

# Adobe Flash Active and Plugin - DOWNLOAD
#==================================================
Function Get-Flash {
    param(
	    [parameter(Mandatory=$true)]
        [string]$RootPath,
        [parameter(Mandatory=$true)]
        [string]$FolderPath,
        [parameter(Mandatory=$false)]
        [ValidateSet('IE', 'Firefox', 'Chrome', 'all')]
        [string]$BrowserSupport= 'all',
        [switch]$Overwrite = $false,
        [switch]$KillBrowsers,
        [switch]$ReturnDetails 
	)

    $SoftObject = @()
    $Publisher = "Adobe"
    $Product = "Flash"

    [string]$SourceURL = "https://get.adobe.com/flashplayer/"
    [string]$DownloadURL = "https://fpdownload.adobe.com/get/flashplayer/pdc/"

    $DestinationPath = Join-Path -Path $RootPath -ChildPath $FolderPath
    If( !(Test-Path $DestinationPath)){
        New-Item $DestinationPath -type directory -ErrorAction SilentlyContinue | Out-Null
    }

    $content = Invoke-WebRequest $SourceURL
    start-sleep 3
    $GetVersion = (($content.AllElements | Select -ExpandProperty outerText | Select-String '^Version (\d+\.)(\d+\.)(\d+\.)(\d+)' | Select -last 1) -split " ")[1]
    $Version = $GetVersion.Trim()
    $LogComment = "Flash latest version is: [$Version]"
     Write-Host $LogComment -ForegroundColor Yellow | Write-Log -logstring $LogComment
    
    $MajorVer = $Version.Split('.')[0]
    
    #Remove all folders and files except the latest if they exist
    Get-ChildItem -Path $DestinationPath -Exclude mms.cfg,disableupdates.bat | Where {$_.Name -notmatch $Version} | foreach ($_) {
        Remove-Item $_.fullname -Recurse -Force | Out-Null
        $LogComment = "Removed... :" + $_.fullname
            Write-Host $LogComment -ForegroundColor DarkMagenta | Write-Log -logstring $LogComment
    }
    #build Destination folder based on version
    New-Item -Path "$DestinationPath\$Version" -type directory -ErrorAction SilentlyContinue | Out-Null

    switch($BrowserSupport){
        'IE' {$types = 'active_x'}
        'Firefox' {$types = 'plugin'}
        'Chrome' {$types = 'ppapi'}
        'all' {$types = 'active_x','plugin','ppapi'}
    }

    Foreach ($type in $types){
        $Filename = "install_flash_player_"+$MajorVer+"_"+$type+".msi"
        $DownloadLink = $DownloadURL + $Version + "/" + $Filename

        $ExtensionType = [System.IO.Path]::GetExtension($fileName)

        #$destination = $DestinationPath + "\" + $Filename
        $destination = $DestinationPath + "\" + $Version + "\" + $Filename

        $LogComment = "Validating Download Link: $DownloadLink"
        Write-Host $LogComment -ForegroundColor DarkYellow | Write-Log -logstring $LogComment
        
        If ( (Test-Path "$destination" -ErrorAction SilentlyContinue) -and !$Overwrite){
            $LogComment = "$Filename is already downloaded"
             Write-Host $LogComment -ForegroundColor Gray | Write-Log -logstring $LogComment
        }
        Else{
            Try{
                #$wc.DownloadFile($DownloadLink, $destination)
                Download-FileProgress -url $DownloadLink -targetFile $destination
                $LogComment = ("Succesfully downloaded: " + $Filename + " to $destination")
                 Write-Host $LogComment -ForegroundColor Green | Write-Log -logstring $LogComment   
            } Catch {
                $LogComment = ("failed to download to: [{0}]" -f $destination)
                 Write-Host $LogComment -ForegroundColor Red | Write-Log -logstring $LogComment
            }
        }

        If($KillBrowsers){
            Get-Process "firefox" -ErrorAction SilentlyContinue | Stop-Process -Force
            Get-Process "iexplore" -ErrorAction SilentlyContinue | Stop-Process -Force
            Get-Process "chrome" -ErrorAction SilentlyContinue | Stop-Process -Force
        }

        #build array of software for inventory
        $SoftObject += new-object psobject -property @{
            FilePath=$destination
            Version=$Version
            File=$Filename
            Publisher=$Publisher
            Product=$Product
            Arch=''
            Language=''
            FileType=$ExtensionType
            ProductType=$type
        }

    }

    If($ReturnDetails){
        return $SoftObject
    }
}


# Adobe Flash Active and Plugin - DOWNLOAD
#==================================================
Function Get-Shockwave {
    #Invoke-WebRequest 'https://get.adobe.com/shockwave/'
    param(
	    [parameter(Mandatory=$true)]
        [string]$RootPath,
        [parameter(Mandatory=$true)]
        [string]$FolderPath,
        [parameter(Mandatory=$false)]
        [ValidateSet('Full', 'Slim', 'MSI', 'All')]
        [string]$Type = 'all',
        [switch]$Overwrite = $false,
        [switch]$KillBrowsers,
        [switch]$ReturnDetails 
        
	)

    $SoftObject = @()
    $Publisher = "Adobe"
    $Product = "Shockwave"

    # Download the Shockwave installer from Adobe
    [string]$SourceURL = "https://get.adobe.com/shockwave/"
    [string]$DownloadURL = "https://www.adobe.com/products/shockwaveplayer/distribution3.html"

    $DestinationPath = Join-Path -Path $RootPath -ChildPath $FolderPath
    If( !(Test-Path $DestinationPath)){
        New-Item $DestinationPath -type directory -ErrorAction SilentlyContinue | Out-Null
    }

    $content = Invoke-WebRequest $SourceURL
    start-sleep 3
    $GetVersion = (($content.AllElements | Select -ExpandProperty outerText | Select-String '^Version (\d+\.)(\d+\.)(\d+\.)(\d+)' | Select -last 1) -split " ")[1]
    $Version = $GetVersion.Trim()
    $LogComment = "Shockwave latest version is: [$Version]"
     Write-Host $LogComment -ForegroundColor Yellow | Write-Log -logstring $LogComment

    $content = Invoke-WebRequest $DownloadURL
    start-sleep 3

    #Remove all folders and files except the latest if they exist
    Get-ChildItem -Path $DestinationPath | Where {$_.Name -notmatch $Version} | foreach ($_) {
        Remove-Item $_.fullname -Recurse -Force | Out-Null
        $LogComment = "Removed... :" + $_.fullname
            Write-Host $LogComment -ForegroundColor DarkMagenta | Write-Log -logstring $LogComment
    }
    #build Destination folder based on version
    New-Item -Path "$DestinationPath\$Version" -type directory -ErrorAction SilentlyContinue | Out-Null

    switch($Type){
        'Full' {$shockwaveLinks = Get-HrefMatches -content [string]$content | Where-Object {$_ -like "*Full*"} | Select -First 1}
        'Slim' {$shockwaveLinks = Get-HrefMatches -content [string]$content | Where-Object {$_ -like "*Slim*"} | Select -First 1}
        'MSI' {$shockwaveLinks = Get-HrefMatches -content [string]$content | Where-Object {$_ -like "*MSI*"} | Select -First 1}
        'All' {$shockwaveLinks = Get-HrefMatches -content [string]$content | Where-Object {$_ -like "*installer"} | Select -First 3}
    }


    Foreach ($link in $shockwaveLinks){
        $DownloadLink = "https://www.adobe.com" + $link
        #name file based on link url
        $filename = $link.replace("/go/sw_","sw_lic_")
        
        #add on extension based on name
        If($filename -match 'msi'){$filename=$filename + '.msi'}
        If($filename -match 'exe'){$filename=$filename + '.exe'}

        $ExtensionType = [System.IO.Path]::GetExtension($fileName)

        # Break up file name by underscore, sw_full_exe_installer
        $ProductType = $fileName.Split('_')[2]
        
        #$destination = $DestinationPath + "\" + $Filename
        $destination = $DestinationPath + "\" + $Version + "\" + $Filename

        $LogComment = "Validating Download Link: $DownloadLink"
        Write-Host $LogComment -ForegroundColor DarkYellow | Write-Log -logstring $LogComment
        
        If ( (Test-Path "$destination" -ErrorAction SilentlyContinue) -and !$Overwrite){
            $LogComment = "$Filename is already downloaded"
                Write-Host $LogComment -ForegroundColor Gray | Write-Log -logstring $LogComment
        }
        Else{
            Try{
                #$wc.DownloadFile($DownloadLink, $destination)
                Download-FileProgress -url $DownloadLink -targetFile $destination
                $LogComment = ("Succesfully downloaded: " + $Filename + " to $destination")
                    Write-Host $LogComment -ForegroundColor Green | Write-Log -logstring $LogComment   
            } 
            Catch {
                $LogComment = ("failed to download to: [{0}]" -f $destination)
                    Write-Host $LogComment -ForegroundColor Red | Write-Log -logstring $LogComment
            }
        }

        If($KillBrowsers){
            Get-Process "firefox" -ErrorAction SilentlyContinue | Stop-Process -Force
            Get-Process "iexplore" -ErrorAction SilentlyContinue | Stop-Process -Force
            Get-Process "chrome" -ErrorAction SilentlyContinue | Stop-Process -Force
        }

        #build array of software for inventory
        $SoftObject += new-object psobject -property @{
            FilePath=$destination
            Version=$Version
            File=$Filename
            Publisher=$Publisher
            Product=$Product
            Arch=''
            Language=''
            FileType=$ExtensionType
            ProductType=$ProductType
        }

    }

    If($ReturnDetails){
        return $SoftObject
    }
}


# Adobe Acrobat Reader DC - DOWNLOAD
#==================================================
Function Get-ReaderDC {
    param(
	    [parameter(Mandatory=$true)]
        [string]$RootPath,
        [parameter(Mandatory=$true)]
        [string]$FolderPath,
        [parameter(Mandatory=$false)]
        [switch]$AllLangToo = $true,
        [switch]$UpdatesOnly,
        [switch]$Overwrite = $false,
        [switch]$KillBrowsers,
        [switch]$ReturnDetails 
	)

    $SoftObject = @()
    $Publisher = "Adobe"
    $Product = "Acrobat Reader DC"

    [string]$SourceURL = "https://supportdownloads.adobe.com/product.jsp?product=10&platform=Windows"
    [string]$DownloadURL = "http://ardownload.adobe.com"

    $DestinationPath = Join-Path -Path $RootPath -ChildPath $FolderPath
    If( !(Test-Path $DestinationPath)){
        New-Item $DestinationPath -type directory -ErrorAction SilentlyContinue | Out-Null
    }

    $content = Invoke-WebRequest $SourceURL
    start-sleep 3
    $ReaderTable = ($content.ParsedHtml.getElementsByTagName('table') | Where{ $_.className -eq 'max' } ).innerHTML
    
    [string]$Version = (($content.AllElements | Select -ExpandProperty outerText | Select-String "^Version*" | Select -First 1) -split " ")[1]
    [version]$VersionDataType = $Version
    [string]$MajorVersion = $VersionDataType.Major
    [string]$MinorVersion = $VersionDataType.Minor
    [string]$MainVersion = $MajorVersion + '.' + $MinorVersion
    
    $Hyperlinks = Get-Hyperlinks -content [string]$ReaderTable

    #Remove all folders and files except the latest if they exist
    Get-ChildItem -Path $DestinationPath | Where {$_.Name -notmatch $Version} | foreach ($_) {
        Remove-Item $_.fullname -Recurse -Force | Out-Null
        $LogComment = "Removed... :" + $_.fullname
            Write-Host $LogComment -ForegroundColor DarkMagenta | Write-Log -logstring $LogComment
    }

    #build Destination folder based on version
    New-Item -Path "$DestinationPath\$Version" -type directory -ErrorAction SilentlyContinue | Out-Null


    ###### Download Reader DC Versions ##############################################

    switch($UpdatesOnly){
        $false {
                    If($AllLangToo){[int32]$selectNum = 3}Else{[int32]$selectNum = 2};
                    $DownloadLinks = $Hyperlinks | Where-Object {$_.Text -like "Adobe Acrobat Reader*"} | Select -First 2
                    $LogComment = "Adobe Acrobat Reader's latest version is: [$MainVersion] and patch version is: [$StringVersion]"
                }

        $true {
                    If($AllLangToo){[int32]$selectNum = 2}Else{[int32]$selectNum = 1};
                    $DownloadLinks = $Hyperlinks | Where-Object {$_.Text -like "Adobe Acrobat Reader*"} | Select -First 2
                    $LogComment = "Adobe Acrobat Reader's latest Patch version is: [$Version]"
                }

        default {
                    If($AllLangToo){[int32]$selectNum = 2}Else{[int32]$selectNum = 1};
                    $DownloadLinks = $Hyperlinks | Where-Object {$_.Text -like "Adobe Acrobat Reader*"} | Select -First 2
                    $LogComment = "Adobe Acrobat Reader's latest Patch version is: [$Version]"
                }

    }

    Foreach($link in $DownloadLinks){
        $SourceURI = [System.Uri]$SourceURL 
        If($SourceURI.PathAndQuery -ne $null){
            $DetailSource = ($SourceURL.replace($SourceURI.PathAndQuery ,"") + '/' + $link.Href)
        }
        Else{
            $DetailSource = ($SourceURL + '/' + $link.Href)
        }
        $DetailContent = Invoke-WebRequest $DetailSource
        start-sleep 3
       
        $DetailInfo = $DetailContent.AllElements | Select -ExpandProperty outerHTML 
        $DetailName = $DetailContent.AllElements | Select -ExpandProperty outerHTML | Where-Object {$_ -like "*AcroRdr*"} | Select -Last 1
        $DetailVersion = $DetailContent.AllElements | Select -ExpandProperty outerText | Select-String '^Version(\d+)'
        [string]$Version = $DetailVersion -replace "Version"
        $PatchName = [string]$DetailName -replace "<[^>]*?>|<[^>]*>",""
        $LogComment = "Adobe Acrobat Reader DC latest Patch version is: [$Version]"
         Write-Host $LogComment -ForegroundColor Yellow | Write-Log -logstring $LogComment

        $DownloadConfirmLink = Get-HrefMatches -content [string]$DetailInfo | Where-Object {$_ -like "thankyou.jsp*"} | Select -First 1
        $DownloadSource = ($SourceURL.replace($SourceURI.PathAndQuery ,"") + '/' + $DownloadConfirmLink).Replace("&amp;","&")
        #$LogComment = "Getting source from: $DownloadSource"
        # Write-Host $LogComment -ForegroundColor DarkYellow | Write-Log $LogComment
        $DownloadContent = Invoke-WebRequest $DownloadSource -UseBasicParsing
        $DownloadLink = Get-HrefMatches -content [string]$DownloadContent | Where-Object {$_ -like "$DownloadURL/*"} | Select -First 1

        $LogComment = "Verifying link is valid: $DownloadLink"
         Write-Host $LogComment -ForegroundColor DarkYellow | Write-Log $LogComment
        $Filename = $DownloadLink | Split-Path -Leaf
        $ExtensionType = [System.IO.Path]::GetExtension($fileName)
        
        If($Filename -match 'MUI'){
            $ProductType = 'MUI'
        } 
        Else {
            $ProductType = ''
        }

        #Adobe's versioning does not include dots (.) or the first two digits
        $fileversion = $Version.replace('.','').substring(2)

        #$destination = $DestinationPath + "\" + $Filename
        $destination = $DestinationPath + "\" + $Version + "\" + $Filename

        If ( (Test-Path $destination -ErrorAction SilentlyContinue) -and !$Overwrite){
            $LogComment = "Adobe Acrobat Reader DC latest patch is already downloaded"
             Write-Host $LogComment -ForegroundColor Gray | Write-Log -logstring $LogComment
        } 
        Else {
            Try{
                Download-FileProgress -url $DownloadLink -targetFile $destination
                #$wc.DownloadFile($DownloadLink, $destination) 
                 $LogComment = ("Succesfully downloaded Adobe Acrobat Reader DC Patch: " + $Filename)
                  Write-Host $LogComment -ForegroundColor Green | Write-Log -logstring $LogComment
            } 
            Catch {
                 $LogComment = ("failed to download to: [{0}]" -f $destination)
                  Write-Host $LogComment -ForegroundColor Red | Write-Log -logstring $LogComment
            }
        }

        If($KillBrowsers){
            Get-Process "firefox" -ErrorAction SilentlyContinue | Stop-Process -Force
            Get-Process "iexplore" -ErrorAction SilentlyContinue | Stop-Process -Force
            Get-Process "chrome" -ErrorAction SilentlyContinue | Stop-Process -Force
        }

        If(Test-Path $destination){
            #build array of software for inventory
            $SoftObject += new-object psobject -property @{
                FilePath=$destination
                Version=$Version
                File=$Filename
                Publisher=$Publisher
                Product=$Product
                Arch=''
                Language=''
                FileType=$ExtensionType
                ProductType=$ProductType
            }
        }

    }

    If($ReturnDetails){
        return $SoftObject
    }
}

# Adobe Reader Full Release - DOWNLOAD
#==================================================
Function Get-Reader{
    param(
	    [parameter(Mandatory=$true)]
        [string]$RootPath,
        [parameter(Mandatory=$true)]
        [string]$FolderPath,
        [parameter(Mandatory=$false)]
        [switch]$AllLangToo = $true,
        [switch]$UpdatesOnly,
        [switch]$Overwrite = $false,
        [switch]$ReturnDetails 
	)
    
    $SoftObject = @()
    $Publisher = "Adobe"
    $Product = "Reader"

    [string]$SourceURL = "http://www.adobe.com/support/downloads/product.jsp?product=10&platform=Windows"
    [string]$LastVersion = '11'

    $DestinationPath = Join-Path -Path $RootPath -ChildPath $FolderPath
    If( !(Test-Path $DestinationPath)){
        New-Item $DestinationPath -type directory -ErrorAction SilentlyContinue | Out-Null
    }

    $content = Invoke-WebRequest $SourceURL
    start-sleep 3
    $ReaderTable = ($content.ParsedHtml.getElementsByTagName('table') | Where{ $_.className -eq 'max' } ).innerHTML
    $Hyperlinks = Get-Hyperlinks -content [string]$ReaderTable

    [string]$Version = (($content.AllElements | Select -ExpandProperty outerText | Select-String "^Version $LastVersion*" | Select -First 1) -split " ")[1]
    [version]$VersionDataType = $Version
    [string]$MajorVersion = $VersionDataType.Major
    [string]$MinorVersion = $VersionDataType.Minor
    [string]$MainVersion = $MajorVersion + '.' + $MinorVersion
    
    #Remove all folders and files except the latest if they exist
    Get-ChildItem -Path $DestinationPath | Where {$_.Name -notmatch $Version} | foreach ($_) {
        Remove-Item $_.fullname -Recurse -Force | Out-Null
        $LogComment = "Removed... :" + $_.fullname
            Write-Host $LogComment -ForegroundColor DarkMagenta | Write-Log -logstring $LogComment
    }
    #build Destination folder based on version
    New-Item -Path "$DestinationPath\$Version" -type directory -ErrorAction SilentlyContinue | Out-Null

    switch($UpdatesOnly){
        $false {
                    If($AllLangToo){[int32]$selectNum = 3}Else{[int32]$selectNum = 2};
                    $DownloadLinks = $Hyperlinks | Where-Object {$_.Text -like "Adobe Reader $MainVersion*"} | Select -First $selectNum
                    $LogComment = "Adobe Reader's latest version is: [$MainVersion] and patch version is: [$Version]"
                }

        $true {
                    If($AllLangToo){[int32]$selectNum = 2}Else{[int32]$selectNum = 1};
                    $DownloadLinks = $Hyperlinks | Where-Object {$_.Text -like "*$Version update*"} | Select -First $selectNum
                    $LogComment = "Adobe Reader's latest Patch version is: [$Version]"
                }
        default {
                    If($AllLangToo){[int32]$selectNum = 2}Else{[int32]$selectNum = 1};
                    $DownloadLinks = $Hyperlinks | Where-Object {$_.Text -like "*$Version update*"} | Select -First $selectNum
                    $LogComment = "Adobe Reader's latest Patch version is: [$Version]"
                }

    }

    Write-Host $LogComment -ForegroundColor Yellow | Write-Log -logstring $LogComment

    Foreach($link in $DownloadLinks){
        $DetailSource = ($DownloadURL + $link.Href)
        $DetailContent = Invoke-WebRequest $DetailSource
        start-sleep 3
        $DetailInfo = $DetailContent.AllElements | Select -ExpandProperty outerHTML 
        $DetailName = $DetailContent.AllElements | Select -ExpandProperty outerHTML | Where-Object {$_ -like "*AdbeRdr*"} | Select -Last 1
        
        $DownloadLink = Get-HrefMatches -content [string]$DetailInfo | Where-Object {$_ -like "thankyou.jsp*"} | Select -First 1
        $DownloadSource = ($DownloadURL + $DownloadLink).Replace("&amp;","&")
        $LogComment = "Getting source from: $DownloadSource"
         Write-Host $LogComment -ForegroundColor DarkYellow | Write-Log -logstring $LogComment
        
        $DownloadContent = Invoke-WebRequest $DownloadSource -UseBasicParsing
        $DownloadFinalLink = Get-HrefMatches -content [string]$DownloadContent | Where-Object {$_ -like "http://ardownload.adobe.com/*"} | Select -First 1

        $LogComment = "Verifying link is valid: $DownloadFinalLink"
         Write-Host $LogComment -ForegroundColor DarkYellow | Write-Log -logstring $LogComment
        
        $Filename = $DownloadFinalLink | Split-Path -Leaf
        #$destination = $DestinationPath + "\" + $Filename
        $destination = $DestinationPath + "\" + $Version + "\" + $Filename

        If($Filename -notmatch "Upd"){
            $ProductLabel = ""
        }
        Else{
            $ProductLabel = "Update"
        }
     
        If($Filename -match 'MUI'){
            $ProductType = 'MUI'
        } Else {
            $ProductType = ''
        }

        $ExtensionType = [System.IO.Path]::GetExtension($fileName)

        $fileversion = $MainVersion.replace('.','')
        
        
        If ( (Test-Path $destination -ErrorAction SilentlyContinue) -and !$Overwrite){
            $LogComment = "Adobe Reader $ProductLabel is already downloaded"
             Write-Host $LogComment -ForegroundColor Gray | Write-Log -logstring $LogComment
        } 
        Else {
            Try{
                Download-FileProgress -url $DownloadFinalLink -targetFile $destination
                #$wc.DownloadFile($DownloadFinalLink, $destination) 
                $LogComment = ("Succesfully downloaded Adobe Reader $ProductLabel : " + $Filename)
                 Write-Host $LogComment -ForegroundColor Green | Write-Log -logstring $LogComment
                If($Filename -notmatch "Upd"){
                    $AdobeReaderMajorPath = $DestinationPath + "\" + $MainVersion
                    New-Item -Path $AdobeReaderMajorPath -Type Directory -ErrorAction SilentlyContinue | Out-Null
                    Expand-Archive $destination -DestinationPath $AdobeReaderMajorPath
               }
                #Remove-Item $destination -Force -ErrorAction SilentlyContinue | Out-Null
            } 
            Catch {
                $LogComment = ("failed to download to: [{0}]" -f $destination)
                 Write-Host $LogComment -ForegroundColor Red | Write-Log -logstring $LogComment
            }
        }

        If($KillBrowsers){
            Get-Process "firefox" -ErrorAction SilentlyContinue | Stop-Process -Force
            Get-Process "iexplore" -ErrorAction SilentlyContinue | Stop-Process -Force
            Get-Process "chrome" -ErrorAction SilentlyContinue | Stop-Process -Force
        }

        #build array of software for inventory
        $SoftObject += new-object psobject -property @{
            FilePath=$destination
            Version=$Version
            File=$Filename
            Publisher=$Publisher
            Product=$Product
            Arch=''
            Language=''
            FileType=$ExtensionType
            ProductType=$ProductType 
        }

    }

    If($ReturnDetails){
        return $SoftObject
    }

}


# Notepad Plus Plus - DOWNLOAD
#==================================================
Function Get-NotepadPlusPlus{
    param(
	    [parameter(Mandatory=$true)]
        [string]$RootPath,
        [parameter(Mandatory=$true)]
        [string]$FolderPath,
        [parameter(Mandatory=$false)]
        [ValidateSet('x86', 'x64', 'Both')]
        [string]$Arch = 'Both',
        [parameter(Mandatory=$false)]
        [switch]$Overwrite = $false,
        [switch]$ReturnDetails 
	)
    
    $SoftObject = @()
    $Publisher = "Notepad++"
    $Product = "Notepad++"

    [string]$SourceURL = "https://notepad-plus-plus.org"
    [string]$DownloadURL = "https://notepad-plus-plus.org/download/v"

    $DestinationPath = Join-Path -Path $RootPath -ChildPath $FolderPath
    If( !(Test-Path $DestinationPath)){
        New-Item $DestinationPath -type directory -ErrorAction SilentlyContinue | Out-Null
    }

    $content = Invoke-WebRequest $SourceURL
    start-sleep 3
    $GetVersion = $content.AllElements | Where id -eq "download" | Select -First 1 -ExpandProperty outerText
    $Version = $GetVersion.Split(":").Trim()[1]
    $LogComment = "Notepad++ latest version is: [$Version]"
     Write-Host $LogComment -ForegroundColor Yellow | Write-Log -logstring $LogComment
    
    $DownloadSource = ($DownloadURL+$Version+".html")
    $DownloadContent = Invoke-WebRequest $DownloadSource
    $LogComment = "Parsing $DownloadSource for download link"
     Write-Host $LogComment -ForegroundColor DarkYellow | Write-Log -logstring $LogComment
    $DownloadInfo = $DownloadContent.AllElements | Select -ExpandProperty outerHTML 

    #Remove all folders and files except the latest if they exist
    Get-ChildItem -Path $DestinationPath -Exclude Aspell* | Where {$_.Name -notmatch $Version} | foreach ($_) {
        Remove-Item $_.fullname -Recurse -Force | Out-Null
        $LogComment = "Removed... :" + $_.fullname
            Write-Host $LogComment -ForegroundColor DarkMagenta | Write-Log -logstring $LogComment
    }
    #build Destination folder based on version
    New-Item -Path "$DestinationPath\$Version" -type directory -ErrorAction SilentlyContinue | Out-Null

    switch($Arch){
        'x86' {$DownloadLinks = Get-HrefMatches -content [string]$DownloadInfo | Where-Object {($_ -like "*/repository/*") -and ($_ -like "*Installer*")} | Select -First 1}
        'x64' {$DownloadLinks = Get-HrefMatches -content [string]$DownloadInfo | Where-Object {($_ -like "*/repository/*") -and ($_ -like "*Installer.x64*")} | Select -First 1}
        'Both' {$DownloadLinks = Get-HrefMatches -content [string]$DownloadInfo | Where-Object {($_ -like "*/repository/*") -and ($_ -like "*Installer*")} | Select -First 2}
    }

    Foreach($link in $DownloadLinks){
        $DownloadLink = $SourceURL+$link.Href
        $Filename = $link | Split-Path -Leaf
        $destination = $DestinationPath + "\" + $Version + "\" + $Filename

        #if match is found, set label
        If($Filename -match '.x64'){
            $ArchLabel = "x64"
        }Else{
            $ArchLabel = "x86"
        }

        $ExtensionType = [System.IO.Path]::GetExtension($fileName)

        $LogComment = "Validating download link: $DownloadLink"
         Write-Host $LogComment -ForegroundColor DarkYellow | Write-Log -logstring $LogComment

        If ( (Test-Path "$destination" -ErrorAction SilentlyContinue) -and !$Overwrite){
            $LogComment = "$Filename is already downloaded"
             Write-Host $LogComment -ForegroundColor Gray | Write-Log -logstring $LogComment
        }
        Else{
            Try{
                #$wc.DownloadFile($DownloadLink, $destination)
                Download-FileProgress -url $link -targetFile $destination
                $LogComment = ("Succesfully downloaded: " + $Filename + " to $destination")
                 Write-Host $LogComment -ForegroundColor Green | Write-Log -logstring $LogComment   
            } 
            Catch {
                $LogComment = ("failed to download to: [{0}]" -f $destination)
                 Write-Host $LogComment -ForegroundColor Red | Write-Log -logstring $LogComment
            }
        }
    
        #build array of software for inventory
        $SoftObject += new-object psobject -property @{
            FilePath=$destination
            Version=$Version
            File=$Filename
            Publisher=$Publisher
            Product=$Product
            Arch=$ArchLabel
            Language=''
            FileType=$ExtensionType
            ProductType='' 
        }

    }

    If($ReturnDetails){
        return $SoftObject
    }

}

# 7zip - DOWNLOAD
#==================================================
Function Get-7Zip{
    param(
	    [parameter(Mandatory=$true)]
        [string]$RootPath,
        [parameter(Mandatory=$true)]
        [string]$FolderPath,
        [parameter(Mandatory=$false)]
        [ValidateSet('EXE (x86)', 'EXE (x64)', 'EXE (Both)','MSI (x86)','MSI (x64)','MSI (Both)','All')]
        [string]$ArchVersion = 'All',
        [switch]$Overwrite = $false,
        [switch]$Beta = $false,
        [switch]$ReturnDetails 
	)
    
    $SoftObject = @()
    $Publisher = "7-zip"
    $Product = "7-zip"

    [string]$SourceURL = "http://www.7-zip.org/download.html"

    $DestinationPath = Join-Path -Path $RootPath -ChildPath $FolderPath
    If( !(Test-Path $DestinationPath)){
        New-Item $DestinationPath -type directory -ErrorAction SilentlyContinue | Out-Null
    }

    $content = Invoke-WebRequest $SourceURL
    start-sleep 3
    
    If($Beta){
        $GetVersion = $content.AllElements | Select -ExpandProperty outerText | Where-Object {$_ -like "Download 7-Zip*"} | Where-Object {$_ -like "*:"} | Select -First 1
    }
    Else{ 
        $GetVersion = $content.AllElements | Select -ExpandProperty outerText | Where-Object {$_ -like "Download 7-Zip*"} | Where-Object {$_ -notlike "*beta*"} | Select -First 1 
    }

    $Version = $GetVersion.Split(" ")[2].Trim()
    $FileVersion = $Version -replace '[^0-9]'
    $LogComment = "7Zip latest version is: [$Version]"
     Write-Host $LogComment -ForegroundColor Yellow | Write-Log -logstring $LogComment

    $Hyperlinks = Get-Hyperlinks -content [string]$content
    #$FilteredLinks = $Hyperlinks | Where {$_.Href -like "*$FileVersion*"} | Where-Object {$_.Href -match '\.(exe|msi)$'}

    #Remove all folders and files except the latest if they exist
    Get-ChildItem -Path $DestinationPath | Where {$_.Name -notmatch $Version} | foreach ($_) {
        Remove-Item $_.fullname -Recurse -Force | Out-Null
        $LogComment = "Removed... :" + $_.fullname
            Write-Host $LogComment -ForegroundColor DarkMagenta | Write-Log -logstring $LogComment
    }
    #build Destination folder based on version
    New-Item -Path "$DestinationPath\$Version" -type directory -ErrorAction SilentlyContinue | Out-Null

    switch($ArchVersion){
        'EXE (x86)' {$DownloadLinks = $Hyperlinks | Where {$_.Href -like "*$FileVersion*"} | Where-Object {$_.Href -match '\.(exe)$'} | Select -First 1 }
        'EXE (x64)' {$DownloadLinks = $Hyperlinks | Where {$_.Href -like "*$FileVersion-x64*"} | Where-Object {$_.Href -match '\.(exe)$'} | Select -First 1 }

        'EXE (Both)' {$DownloadLinks = $Hyperlinks | Where {$_.Href -like "*$FileVersion*"} | Where-Object {$_.Href -match '\.(exe)$'} | Select -First 2 }

        'MSI (x86)' {$DownloadLinks = $Hyperlinks | Where {$_.Href -like "*$FileVersion*"} | Where-Object {$_.Href -match '\.(msi)$'} | Select -First 1 }
        'MSI (x64)' {$DownloadLinks = $Hyperlinks | Where {$_.Href -like "*$FileVersion-x64*"} | Where-Object {$_.Href -match '\.(msi)$'} | Select -First 1 }

        'MSI (Both)' {$DownloadLinks = $Hyperlinks | Where {$_.Href -like "*$FileVersion*"} | Where-Object {$_.Href -match '\.(msi)$'} | Select -First 2 }

        'All' {$DownloadLinks = $Hyperlinks | Where {$_.Href -like "*$FileVersion*"} | Where-Object {$_.Href -match '\.(exe|msi)$'}}
    }

    Foreach($link in $DownloadLinks){
        $DownloadLink = ("http://www.7-zip.org/"+$link.Href)
        $Filename = $DownloadLink | Split-Path -Leaf
        $destination = $DestinationPath + "\" + $Version + "\" + $Filename

        #find what arch the file is based on the integer 64
        $pattern = "(-x)(\d{2})"
        $Filename -match $pattern | Out-Null

        #if match is found, set label
        If($matches){
            $ArchLabel = "x64"
        }Else{
            $ArchLabel = "x86"
        }

        $matches = $null

        $ExtensionType = [System.IO.Path]::GetExtension($fileName)

        $LogComment = "Validating download link: $DownloadLink"
         Write-Host $LogComment -ForegroundColor DarkYellow | Write-Log -logstring $LogComment
        
        If ( (Test-Path "$destination" -ErrorAction SilentlyContinue) -and !$Overwrite){
            $LogComment = "$Filename is already downloaded"
             Write-Host $LogComment -ForegroundColor Gray | Write-Log -logstring $LogComment
        }
        Else{
            Try{
                #$wc.DownloadFile($DownloadLink, $destination)
                Download-FileProgress -url $DownloadLink -targetFile $destination
                $LogComment = ("Succesfully downloaded: " + $Filename + " to $destination")
                 Write-Host $LogComment -ForegroundColor Green | Write-Log -logstring $LogComment   
            } 
            Catch {
                $LogComment = ("failed to download to: [{0}]" -f $destination)
                 Write-Host $LogComment -ForegroundColor Red | Write-Log -logstring $LogComment
            }
        }

        #build array of software for inventory
        $SoftObject += new-object psobject -property @{
            FilePath=$destination
            Version=$Version
            File=$Filename
            Publisher=$Publisher
            Product=$Product
            Arch=$ArchLabel
            Language=''
            FileType=$ExtensionType
            ProductType='' 
        }

    }

    If($ReturnDetails){
        return $SoftObject
    }
}

# VLC (x86 & x64) - DOWNLOAD
#==================================================
Function Get-VLCPlayer{
    param(
	    [parameter(Mandatory=$true)]
        [string]$RootPath,
        [parameter(Mandatory=$true)]
        [string]$FolderPath,
        [parameter(Mandatory=$false)]
        [ValidateSet('x86', 'x64', 'Both')]
        [string]$Arch = 'Both',
        [switch]$Overwrite = $false,
        [switch]$ReturnDetails 

	)
    
    $SoftObject = @()
    $Publisher = "VideoLan"
    $Product = "VLC Media Player"

    [string]$SourceURL = "http://www.videolan.org/vlc/"
    [string]$DownloadURL = "https://download.videolan.org/vlc/last"

    $DestinationPath = Join-Path -Path $RootPath -ChildPath $FolderPath
    If( !(Test-Path $DestinationPath)){
        New-Item $DestinationPath -type directory -ErrorAction SilentlyContinue | Out-Null
    }

    $content = Invoke-WebRequest $SourceURL
    start-sleep 3
    $GetVersion = $content.AllElements | Where id -like "downloadVersion*" | Select -ExpandProperty outerText
    $Version = $GetVersion.Trim()

    #Remove all folders and files except the latest if they exist
    Get-ChildItem -Path $DestinationPath | Where {$_.Name -notmatch $Version} | foreach ($_) {
        Remove-Item $_.fullname -Recurse -Force | Out-Null
        $LogComment = "Removed... :" + $_.fullname
            Write-Host $LogComment -ForegroundColor DarkMagenta | Write-Log -logstring $LogComment
    }
    #build Destination folder based on version
    New-Item -Path "$DestinationPath\$Version" -type directory -ErrorAction SilentlyContinue | Out-Null

    switch($Arch){
        'x86' {$DownloadLinks = "$DownloadURL/win32/vlc-$Version-win32.exe"}
        'x64' {$DownloadLinks = "$DownloadURL/win64/vlc-$Version-win64.exe"}

        'Both' {$DownloadLinks = "$DownloadURL/win32/vlc-$Version-win32.exe",
                                 "$DownloadURL/win64/vlc-$Version-win64.exe" }
    }

    Foreach($link in $DownloadLinks){
        $Filename = $link | Split-Path -Leaf
        $destination = $DestinationPath + "\" + $Version + "\" + $Filename

        #if match is found, set label
        If($Filename -match '-win64'){
            $ArchLabel = "x64"
        }Else{
            $ArchLabel = "x86"
        }

        $ExtensionType = [System.IO.Path]::GetExtension($fileName)

        $LogComment = "Validating download link: $link"
         Write-Host $LogComment -ForegroundColor DarkYellow | Write-Log -logstring $LogComment

        If ( (Test-Path "$destination" -ErrorAction SilentlyContinue) -and !$Overwrite){
            $LogComment = "$Filename is already downloaded"
             Write-Host $LogComment -ForegroundColor Gray | Write-Log -logstring $LogComment
        }
        Else{
            Try{
                #$wc.DownloadFile($DownloadLink, $destination)
                Download-FileProgress -url $link -targetFile $destination
                $LogComment = ("Succesfully downloaded: " + $Filename + " to $destination")
                 Write-Host $LogComment -ForegroundColor Green | Write-Log -logstring $LogComment   
            } 
            Catch {
                $LogComment = ("failed to download to: [{0}]" -f $destination)
                 Write-Host $LogComment -ForegroundColor Red | Write-Log -logstring $LogComment
            }
        }
    
        #build array of software for inventory
        $SoftObject += new-object psobject -property @{
            FilePath=$destination
            Version=$Version
            File=$Filename
            Publisher=$Publisher
            Product=$Product
            Arch=$ArchLabel
            Language=''
            FileType=$ExtensionType
            ProductType='' 
        }

    }

    If($ReturnDetails){
        return $SoftObject
    }
}

# GENERATE INITIAL LOG
#==================================================
$logstamp = logstamp
[string]$LogFolder = Join-Path -Path $scriptRoot -ChildPath 'Logs'
$Logfile =  "$LogFolder\3rdpartydownloads.log"
Write-log -logstring "Checking 3rd Party Updates, Please wait"

#==================================================
# MAIN - DOWNLOAD 3RD PARTY SOFTWARE
#==================================================
## Load the System.Web DLL so that we can decode URLs
Add-Type -Assembly System.Web
$wc = New-Object System.Net.WebClient

# Proxy-Settings
#$wc.Proxy = [System.Net.WebRequest]::DefaultWebProxy
#$wc.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials

#Get-Process "firefox" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
#Get-Process "iexplore" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
#Get-Process "Openwith" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

#Get-Reader -RootPath $3rdPartyFolder -FolderPath 'Reader' -AllLangToo
$list = @()
$list += Get-Java8 -RootPath $3rdPartyFolder -FolderPath 'Java 8' -Arch Both -ReturnDetails
$list += Get-ReaderDC -RootPath $3rdPartyFolder -FolderPath 'ReaderDC' -UpdatesOnly -ReturnDetails
$list += Get-Flash -RootPath $3rdPartyFolder -FolderPath 'Flash' -BrowserSupport all -ReturnDetails
$list += Get-Shockwave -RootPath $3rdPartyFolder -FolderPath 'Shockwave' -Type All -ReturnDetails
 
$list += Get-Firefox -RootPath $3rdPartyFolder -FolderPath 'Firefox' -Arch Both -ReturnDetails
$list += Get-NotepadPlusPlus -RootPath $3rdPartyFolder -FolderPath 'NotepadPlusPlus' -ReturnDetails
$list += Get-7Zip -RootPath $3rdPartyFolder -FolderPath '7Zip' -ArchVersion All -ReturnDetails
$list += Get-VLCPlayer -RootPath $3rdPartyFolder -FolderPath 'VLC Player' -Arch Both -ReturnDetails
$list += Get-Chrome -RootPath $3rdPartyFolder -FolderPath 'Chrome' -ArchType All -ReturnDetails

$list | Export-Clixml $3rdPartyFolder\softwarelist.xml