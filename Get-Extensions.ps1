[CmdletBinding()]
param (
    [Switch]$EnablePermissions,
    [Switch]$EnableDefaultExtensions
)

function Get-Extensions {
    Foreach ( $User in (Get-ChildItem -Directory -Path "$env:SystemDrive\Users") ) {

        # Get Profiles folder
        $ProfilesDir = $User.FullName + "\AppData\Roaming\Mozilla\Firefox\Profiles"

        # Skip this round of the loop if no Profiles folder is present
        if ( -Not (Test-Path $ProfilesDir) ) {

            Continue

        }

        Foreach ( $ExtensionFile in (Get-ChildItem -Path $ProfilesDir -File -Filter "extensions.json" -Recurse)) {

            $ExtensionDir = $ExtensionFile.DirectoryName
        
            # Get Firefox version - yes it is in the loop. Had to determine profile location.
            $FirefoxVersion = $null
            Foreach ( $Line in (Get-Content "$ExtensionDir\compatibility.ini" -ErrorAction SilentlyContinue) ) {

                if ( $Line.StartsWith("LastVersion") ) {

                    # Split on = and _, then grab the first element
                    $FirefoxVersion = ($Line -split "[=_]")[1]

                }

            }
        
            # Read extensions JSON file
            $ExtensionJson = (Get-Content $ExtensionFile.FullName | ConvertFrom-Json).Addons

            Foreach ( $Extension in $ExtensionJson ) {
                
                $Location = $Extension.Location

                # Skip default extensions
                if ( -Not $EnableDefaultExtensions ) {

                    if ( "app-builtin", "app-system-defaults" -contains $Location ) {

                        Continue

                    }

                }
            
                # Convert InstallDate
                $InstallTime = [Double]$Extension.InstallDate
                # Divide by 1,000 because we are going to add seconds on to the base date
                $InstallTime = $InstallTime / 1000
                $UtcTime = Get-Date -Date "1970-01-01 00:00:00"
                $UtcTime = $UtcTime.AddSeconds($InstallTime)
                $LocalTime = [System.TimeZoneInfo]::ConvertTimeFromUtc($UtcTime, (Get-TimeZone))
        
                $Output = [Ordered]@{
                    Browser      = [String]  'Mozilla Firefox'
                    User         = [String]  $User
                    Name         = [String]  $Extension.DefaultLocale.Name
                    Version      = [String]  $Extension.Version
                    Enabled      = [Bool]    $Extension.Active
                    InstallDate  = [DateTime]$LocalTime
                    Description  = [String]  $Extension.DefaultLocale.Description
                    ID           = [String]  $Extension.Id
                    FirefoxVer   = [String]  $FirefoxVersion
                    Visible      = [Bool]    $Extension.Visible
                    AppDisabled  = [Bool]    $Extension.AppDisabled
                    UserDisabled = [Bool]    $Extension.UserDisabled
                    Hidden       = [Bool]    $Extension.Hidden
                    Location     = [String]  $Location
                    SourceUri    = [String]  $Extension.SourceUri
                }

                if ( $EnablePermissions ) {

                    # Convert Permissions array into a multi-line string
                    # This multi-line string is kind of ugly in Inventory, so it's disabled by default
                    $Output.Permissions = [String]($Extension.UserPermissions.Permissions -Join "`n")

                }

                [PSCustomObject]$Output
        
            }

        }

    }

    $Template = @{
        'AppData'      = 'Local'
        'LastVersion'  = 'last_chrome_version'
        # 'Default*' is intentionally a wildcard to prevent errors if it is missing.
        # https://github.com/pdq/PowerShell-Scanners/pull/54#discussion_r626112183
        'ProfileNames' = 'Default*', 'Profile*'
        'Settings'     = 'settings'
    }
    $BrowserTable = @{
        'Brave'          = $Template.Clone()
        'Chromium'       = $Template.Clone()
        'Google Chrome'  = $Template.Clone()
        'Microsoft Edge' = $Template.Clone()
        # Opera, why do you have to be so different? :'(
        'Opera'          = @{
            'AppData'      = 'Roaming'
            'LastVersion'  = 'last_opera_version'
            'ProfileBase'  = 'Opera Software'
            'ProfileNames' = 'Opera*'
            'Settings'     = 'opsettings'
        }
        'Vivaldi'        = $Template.Clone()
    }
    $BrowserTable.Brave.ProfileBase = 'BraveSoftware\Brave-Browser\User Data'
    $BrowserTable.Chromium.ProfileBase = 'Chromium\User Data'
    $BrowserTable.'Google Chrome'.ProfileBase = 'Google\Chrome\User Data'
    $BrowserTable.'Microsoft Edge'.ProfileBase = 'Microsoft\Edge\User Data'
    $BrowserTable.Vivaldi.ProfileBase = 'Vivaldi\User Data'


    # Set up or check the list of browsers to scan.
    if ( -not $Browsers ) {

        $Browsers = $BrowserTable.Keys

    } else {

        Foreach ( $BrowserName in $Browsers ) {

            if ( $BrowserName -notin $BrowserTable.Keys ) {

                throw "'$BrowserName' does not match any entries in the list of supported browsers."

            }

        }

    }

    # Set up the JSON parser for the Preferences files below.
    # This .NET method is necessary because ConvertFrom-Json can't handle duplicate entries with different cases.
    # https://github.com/pdq/PowerShell-Scanners/issues/23
    Add-Type -AssemblyName System.Web.Extensions
    $JsonParser = New-Object -TypeName System.Web.Script.Serialization.JavaScriptSerializer

    $TimeZone = [TimeZoneInfo]::Local
    $Epoch = Get-Date -Date '1970-01-01 00:00:00'

    Foreach ( $User in (Get-ChildItem -Directory -Path "$env:SystemDrive\Users") ) {

        Foreach ( $BrowserName in $Browsers ) {

            $Browser = $BrowserTable.$BrowserName
    
            # Get profiles.
            $ProfileBase = "$($User.FullName)\AppData\$($Browser.AppData)\$($Browser.ProfileBase)"
            if ( Test-Path $ProfileBase ) {

                Set-Location -Path $ProfileBase

            } else {

                # Browser is not installed, or the user has never opened it.
                Continue

            }
            $Profiles = Get-Item -Path $Browser.ProfileNames

            Foreach ( $Profile in $Profiles ) {

                $BrowserSettings = $null
        
                $SecurePreferencesFile = "$($Profile.FullName)\Secure Preferences"
                $SecurePreferencesJson = $null
                if ( Test-Path $SecurePreferencesFile ) {

                    $SecurePreferencesText = Get-Content -Raw $SecurePreferencesFile
                    $SecurePreferencesJson = $JsonParser.DeserializeObject($SecurePreferencesText)
                
                    # See if this file contains extension data.
                    if ( $SecurePreferencesJson.extensions."$($Browser.Settings)" ) {

                        $BrowserSettings = $SecurePreferencesJson.extensions."$($Browser.Settings)".GetEnumerator()
                    
                    } else {
                    
                        Write-Verbose "Unable to find the extensions.$($Browser.Settings) node in: $SecurePreferencesFile"

                    }

                } else {

                    Write-Verbose "Unable to find a 'Secure Preferences' file in: $($Profile.FullName)"

                }

                $PreferencesFile = "$($Profile.FullName)\Preferences"
                $PreferencesJson = $null
                if ( Test-Path $PreferencesFile ) {

                    # The only thing we care about in Preferences is the last browser version.
                    $PreferencesText = Get-Content -Raw $PreferencesFile
                    $PreferencesJson = $JsonParser.DeserializeObject($PreferencesText)

                    # Check for extension data if it wasn't in SecurePreferences.
                    if ( -not $BrowserSettings ) {

                        if ( $PreferencesJson.extensions."$($Browser.Settings)" ) {

                            Write-Verbose "Falling back to Preferences file for: $($Profile.FullName)"
                            $BrowserSettings = $PreferencesJson.extensions."$($Browser.Settings)".GetEnumerator()
                        
                        } else {
                        
                            Write-Verbose "Unable to find the extensions.$($Browser.Settings) node in: $PreferencesFile"
                            Write-Verbose "No extension data found for: $($Profile.FullName), moving to the next profile"
                            Continue
    
                        }

                    }

                } else {

                    Write-Verbose "Unable to find a 'Preferences' file in: $($Profile.FullName)"

                }

                if ( -not $BrowserSettings ) {

                    Write-Verbose "No Preferences files found in: $($Profile.FullName), moving to the next profile"
                    Continue

                }

                Foreach ( $Extension in $BrowserSettings ) {

                    $ID = $Extension.Key
                    $Extension = $Extension.Value
                    $Name = $Extension.manifest.name

                    # Ignore blank names.
                    if ( -Not $Name ) {

                        Write-Verbose "Blank name for ID '$ID' in: $SecurePreferencesFile"
                        Continue

                    }

                    # Convert install_time from Webkit format.
                    $InstallTime = [Double]$Extension.install_time
                    # Divide by 1,000,000 because we are going to add seconds on to the base date.
                    $InstallTime = ($InstallTime - 11644473600000000) / 1000000
                    $UtcTime = $Epoch.AddSeconds($InstallTime)
                    $InstallDate = [TimeZoneInfo]::ConvertTimeFromUtc($UtcTime, $TimeZone)

                    $Output = [Ordered]@{
                        'Browser'           = [String]  $BrowserName
                        'Name'              = [String]  $Name
                        'Enabled'           = [Bool]    $Extension.state
                        'Description'       = [String]  $Extension.manifest.description
                        'Extension Version' = [String]  $Extension.manifest.version
                        'Browser Version'   = [String]  $PreferencesJson.extensions."$($Browser.LastVersion)"
                        'Default Install'   = [Bool]    $Extension.was_installed_by_default
                        'OEM Install'       = [Bool]    $Extension.was_installed_by_oem
                        'ID'                = [String]  $ID
                        'Install Date'      = [DateTime]$InstallDate
                        'User'              = [String]  $User.Name
                        'Profile'           = [String]  $Profile.Name
                    }

                    if ( $EnablePermissions ) {

                        # Convert Permissions array into a multi-line string.
                        # This multi-line string is kind of ugly in Inventory, so it's disabled by default.
                        $Output.Permissions = [String]($Extension.manifest.permissions -Join "`n")

                    }

                    [PSCustomObject]$Output
            
                }

            }

        }

    }
}

Get-Extensions
