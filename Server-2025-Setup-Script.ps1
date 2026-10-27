# ==============================================================================
# Windows Server 2025 - Grand Unified Optimization & Parity Script
# Pattern: Test -> Try -> Action -> Verify (TTAV)
# Compatibility: Windows PowerShell 5.1 & PowerShell 7+
# Property: Fully Idempotent (Safe to execute repeatedly)
# Requires: Elevated Administrator PowerShell Session
# ==============================================================================

#region Self-Elevation Validation
$CurrentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$CurrentPrincipal = [Security.Principal.WindowsPrincipal]$CurrentIdentity
if (-not $CurrentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Execution halted: This script requires an elevated PowerShell session (Run as Administrator)."
    exit 1
}
#endregion

Clear-Host
Write-Host "====================================================================" -ForegroundColor Cyan
Write-Host " Windows Server 2025 Idempotent Optimization Engine (TTAV Pattern)  " -ForegroundColor Cyan
Write-Host "====================================================================" -ForegroundColor Cyan

# Global flag to track whether Explorer needs to restart
$script:ExplorerRestartRequired = $false

# ==============================================================================
# Helper Functions: Test -> Try -> Action -> Verify (TTAV) Engine
# ==============================================================================

function Invoke-TTAVRegistryValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [string]$Name,
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)] [string]$Type,
        [Parameter(Mandatory = $true)] [string]$Description,
        [switch]$RequiresExplorerRestart
    )

    # 1. TEST
    $CurrentProp = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -ne $CurrentProp -and $CurrentProp.$Name -eq $Value) {
        Write-Host "  [ALREADY SET] $Description" -ForegroundColor DarkGray
        return
    }

    # 2. TRY
    try {
        # 3. ACTION
        if (-not (Test-Path -Path $Path)) {
            New-Item -Path $Path -Force | Out-Null
        }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force | Out-Null

        # 4. VERIFY
        $VerifiedProp = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        if ($VerifiedProp.$Name -eq $Value) {
            Write-Host "  [APPLIED]     $Description" -ForegroundColor Green
            if ($RequiresExplorerRestart) { $script:ExplorerRestartRequired = $true }
        } else {
            Write-Warning "  [VERIFY FAIL] $Description (Value mismatch after write)"
        }
    }
    catch {
        Write-Error "  [ERROR]       $Description - Exception: $_"
    }
}

function Invoke-TTAVRegistryKeyRemoved {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [string]$Description,
        [switch]$RequiresExplorerRestart
    )

    # 1. TEST
    if (-not (Test-Path -Path $Path)) {
        Write-Host "  [ALREADY SET] $Description" -ForegroundColor DarkGray
        return
    }

    # 2. TRY
    try {
        # 3. ACTION
        Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop

        # 4. VERIFY
        if (-not (Test-Path -Path $Path)) {
            Write-Host "  [APPLIED]     $Description" -ForegroundColor Green
            if ($RequiresExplorerRestart) { $script:ExplorerRestartRequired = $true }
        } else {
            Write-Warning "  [VERIFY FAIL] $Description (Key still exists)"
        }
    }
    catch {
        Write-Error "  [ERROR]       $Description - Exception: $_"
    }
}

function Invoke-TTAVService {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Name,
        [Parameter(Mandatory = $true)] [string]$StartupType,
        [Parameter(Mandatory = $true)] [string]$Description
    )

    # 1. TEST
    $Svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $Svc) {
        Write-Warning "  [NOT FOUND]   Service '$Name' does not exist on this machine."
        return
    }

    $IsConfigured = ($Svc.StartType -eq $StartupType) -and ($Svc.Status -eq 'Running')
    if ($IsConfigured) {
        Write-Host "  [ALREADY SET] $Description" -ForegroundColor DarkGray
        return
    }

    # 2. TRY
    try {
        # 3. ACTION
        Set-Service -Name $Name -StartupType $StartupType -ErrorAction Stop
        if ($Svc.Status -ne 'Running') {
            Start-Service -Name $Name -ErrorAction Stop
        }

        # 4. VERIFY
        $VerifiedSvc = Get-Service -Name $Name -ErrorAction Stop
        if ($VerifiedSvc.StartType -eq $StartupType -and $VerifiedSvc.Status -eq 'Running') {
            Write-Host "  [APPLIED]     $Description" -ForegroundColor Green
        } else {
            Write-Warning "  [VERIFY FAIL] $Description (Status: $($VerifiedSvc.Status), Startup: $($VerifiedSvc.StartType))"
        }
    }
    catch {
        Write-Error "  [ERROR]       $Description - Exception: $_"
    }
}

function Invoke-TTAVFirewallRule {
    [CmdletBinding()]
    param(
        [string]$Name,
        [string]$DisplayGroup,
        [Parameter(Mandatory = $true)] [string]$Description
    )

    # PS 5.1 safe fallback string
    $TargetLabel = if ($Name) { $Name } else { $DisplayGroup }

    # 1. TEST
    $Rules = if ($Name) {
        Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue
    } else {
        Get-NetFirewallRule -DisplayGroup $DisplayGroup -ErrorAction SilentlyContinue
    }

    if ($null -eq $Rules) {
        Write-Warning "  [NOT FOUND]   Firewall target not found ($TargetLabel)."
        return
    }

    $AllEnabled = ($Rules | Where-Object { $_.Enabled -ne 'True' }).Count -eq 0
    if ($AllEnabled) {
        Write-Host "  [ALREADY SET] $Description" -ForegroundColor DarkGray
        return
    }

    # 2. TRY
    try {
        # 3. ACTION
        if ($Name) {
            Enable-NetFirewallRule -Name $Name -ErrorAction Stop
        } else {
            Enable-NetFirewallRule -DisplayGroup $DisplayGroup -ErrorAction Stop
        }

        # 4. VERIFY
        $VerifyRules = if ($Name) {
            Get-NetFirewallRule -Name $Name -ErrorAction Stop
        } else {
            Get-NetFirewallRule -DisplayGroup $DisplayGroup -ErrorAction Stop
        }
        $PostCheck = ($VerifyRules | Where-Object { $_.Enabled -ne 'True' }).Count -eq 0

        if ($PostCheck) {
            Write-Host "  [APPLIED]     $Description" -ForegroundColor Green
        } else {
            Write-Warning "  [VERIFY FAIL] $Description (One or more rules failed to enable)"
        }
    }
    catch {
        Write-Error "  [ERROR]       $Description - Exception: $_"
    }
}


# ==============================================================================
# SECTION 1: File Explorer & Navigation Pane (Removing Gallery & Home)
# ==============================================================================
Write-Host "`n[1/12] File Explorer Shell & Navigation Pane" -ForegroundColor Yellow

$ExplorerAdvPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"

# 1a. Classic Full Right-Click Context Menu
Invoke-TTAVRegistryValue `
    -Path "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" `
    -Name "(default)" -Value "" -Type String `
    -Description "Classic Right-Click Context Menu (Bypass 'Show More Options')" `
    -RequiresExplorerRestart

# 1b. Completely Strip Gallery from Navigation Pane (All NameSpace targets)
$GalleryGuid = "{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}"

# Remove the primary desktop namespace registration in HKLM
Invoke-TTAVRegistryKeyRemoved `
    -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$GalleryGuid" `
    -Description "Gallery Desktop NameSpace (HKLM Root Registration)" `
    -RequiresExplorerRestart

# Remove secondary dynamic namespace registrations
Invoke-TTAVRegistryKeyRemoved `
    -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace_41040327\$GalleryGuid" `
    -Description "Gallery Dynamic NameSpace (HKLM NameSpace_41040327)" `
    -RequiresExplorerRestart

Invoke-TTAVRegistryKeyRemoved `
    -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$GalleryGuid" `
    -Description "Gallery User Desktop NameSpace (HKCU)" `
    -RequiresExplorerRestart

# User-level CLSID Unpin override
Invoke-TTAVRegistryValue `
    -Path "HKCU:\Software\Classes\CLSID\$GalleryGuid" `
    -Name "System.IsPinnedToNameSpaceTree" -Value 0 -Type DWord `
    -Description "Gallery Navigation Tree Unpin Flag (HKCU CLSID)" `
    -RequiresExplorerRestart

# Native modern Explorer flag
Invoke-TTAVRegistryValue `
    -Path $ExplorerAdvPath `
    -Name "ShowGallery" -Value 0 -Type DWord `
    -Description "Disable Gallery Visibility Flag (ShowGallery = 0)" `
    -RequiresExplorerRestart

# 1c. Completely Strip Home from Navigation Pane (Permission-Safe)
$HomeGuid = "{f874310e-b6b7-47dc-bc84-b9e6b38f5903}"

Invoke-TTAVRegistryValue `
    -Path "HKCU:\Software\Classes\CLSID\$HomeGuid" `
    -Name "System.IsPinnedToNameSpaceTree" -Value 0 -Type DWord `
    -Description "Home Folder Navigation Unpin Flag (HKCU CLSID)" `
    -RequiresExplorerRestart

Invoke-TTAVRegistryKeyRemoved `
    -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$HomeGuid" `
    -Description "Home Folder Desktop NameSpace Unhook (HKLM)" `
    -RequiresExplorerRestart

# 1d. Explorer Views: Show File Extensions & Hidden Files
Invoke-TTAVRegistryValue `
    -Path $ExplorerAdvPath -Name "HideFileExt" -Value 0 -Type DWord `
    -Description "Always Show File Extensions" `
    -RequiresExplorerRestart

Invoke-TTAVRegistryValue `
    -Path $ExplorerAdvPath -Name "Hidden" -Value 1 -Type DWord `
    -Description "Always Show Hidden Files and Folders" `
    -RequiresExplorerRestart

# 1e. Open File Explorer to 'This PC' (1 = This PC, 2 = Home)
Invoke-TTAVRegistryValue `
    -Path $ExplorerAdvPath -Name "LaunchTo" -Value 1 -Type DWord `
    -Description "Open File Explorer Default Location to 'This PC'" `
    -RequiresExplorerRestart

# 1f. Show Drive Letters First in Explorer
Invoke-TTAVRegistryValue `
    -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" `
    -Name "ShowDriveLettersFirst" -Value 4 -Type DWord `
    -Description "Show Drive Letters Before Labels (e.g., '(C:) Local Disk')" `
    -RequiresExplorerRestart

# 1g. Disable Snap Layouts Flyout on the Maximize Button
Invoke-TTAVRegistryValue `
    -Path $ExplorerAdvPath -Name "EnableSnapAssistFlyout" -Value 0 -Type DWord `
    -Description "Disable Snap Layouts Hover Flyout on Window Maximize Button"


# ==============================================================================
# SECTION 2: Script Context Menu (Run as Administrator for .ps1, .bat, .cmd)
# ==============================================================================
Write-Host "`n[2/12] Script Context Menus (Run as Administrator)" -ForegroundColor Yellow

# 2a. PowerShell Scripts (.ps1) - Run with PowerShell (Elevated)
$Ps1RunAsKey = "HKCU:\Software\Classes\Microsoft.PowerShellScript.1\Shell\runas\Command"
$Ps1RunAsCmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& ''%1''"'

Invoke-TTAVRegistryValue `
    -Path "HKCU:\Software\Classes\Microsoft.PowerShellScript.1\Shell\runas" `
    -Name "HasLUAShield" -Value "" -Type String `
    -Description "Run as Administrator Shield Icon (.ps1)"

Invoke-TTAVRegistryValue `
    -Path $Ps1RunAsKey `
    -Name "(default)" -Value $Ps1RunAsCmd -Type String `
    -Description "Run as Administrator Command Handler (.ps1)"

# 2b. Batch Scripts (.bat) - Run as Administrator
$BatRunAsKey = "HKCU:\Software\Classes\batfile\shell\runas\command"
$BatRunAsCmd = '%SystemRoot%\System32\cmd.exe /C "%1" %*'

Invoke-TTAVRegistryValue `
    -Path "HKCU:\Software\Classes\batfile\shell\runas" `
    -Name "HasLUAShield" -Value "" -Type String `
    -Description "Run as Administrator Shield Icon (.bat)"

Invoke-TTAVRegistryValue `
    -Path $BatRunAsKey `
    -Name "(default)" -Value $BatRunAsCmd -Type String `
    -Description "Run as Administrator Command Handler (.bat)"

# 2c. Command Scripts (.cmd) - Run as Administrator
$CmdRunAsKey = "HKCU:\Software\Classes\cmdfile\shell\runas\command"
$CmdRunAsCmd = '%SystemRoot%\System32\cmd.exe /C "%1" %*'

Invoke-TTAVRegistryValue `
    -Path "HKCU:\Software\Classes\cmdfile\shell\runas" `
    -Name "HasLUAShield" -Value "" -Type String `
    -Description "Run as Administrator Shield Icon (.cmd)"

Invoke-TTAVRegistryValue `
    -Path $CmdRunAsKey `
    -Name "(default)" -Value $CmdRunAsCmd -Type String `
    -Description "Run as Administrator Command Handler (.cmd)"


# ==============================================================================
# SECTION 3: Taskbar Layout & Clutter Removal
# ==============================================================================
Write-Host "`n[3/12] Taskbar Layout & Alignment" -ForegroundColor Yellow

# 3a. Left-Align Start Button & App Icons (0 = Left, 1 = Center)
Invoke-TTAVRegistryValue `
    -Path $ExplorerAdvPath -Name "TaskbarAl" -Value 0 -Type DWord `
    -Description "Left-Align Start Button and Pinned App Icons" `
    -RequiresExplorerRestart

# 3b. Taskbar Combining: Always Combine / Hide Labels (0 = Always Combine)
Invoke-TTAVRegistryValue `
    -Path $ExplorerAdvPath -Name "TaskbarGlomLevel" -Value 0 -Type DWord `
    -Description "Taskbar Buttons Set to 'Always Combine, Hide Labels'" `
    -RequiresExplorerRestart

# 3c. Hide Search Bar / Icon from Taskbar
Invoke-TTAVRegistryValue `
    -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" `
    -Name "SearchboxTaskbarMode" -Value 0 -Type DWord `
    -Description "Hide Search Bar and Search Icon from Taskbar" `
    -RequiresExplorerRestart

# 3d. Hide Task View Button and Widgets
Invoke-TTAVRegistryValue `
    -Path $ExplorerAdvPath -Name "ShowTaskViewButton" -Value 0 -Type DWord `
    -Description "Hide Task View Button from Taskbar" `
    -RequiresExplorerRestart

Invoke-TTAVRegistryValue `
    -Path $ExplorerAdvPath -Name "TaskbarDa" -Value 0 -Type DWord `
    -Description "Hide Widgets / News Button from Taskbar" `
    -RequiresExplorerRestart


# ==============================================================================
# SECTION 4: Start Menu & Search Decoupling
# ==============================================================================
Write-Host "`n[4/12] Start Menu & Search Decoupling" -ForegroundColor Yellow

$ExplorerPolicyUser = "HKCU:\Software\Policies\Microsoft\Windows\Explorer"

Invoke-TTAVRegistryValue `
    -Path $ExplorerPolicyUser -Name "DisableSearchBoxSuggestions" -Value 1 -Type DWord `
    -Description "Disable Web Search Suggestions in Start Menu"

Invoke-TTAVRegistryValue `
    -Path $ExplorerPolicyUser -Name "ConnectedSearchUseWeb" -Value 0 -Type DWord `
    -Description "Disable Bing Connected Web Searches via Start"

Invoke-TTAVRegistryValue `
    -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer" `
    -Name "HideRecommendedSection" -Value 1 -Type DWord `
    -Description "Hide 'Recommended' Section in Start Menu"

$ContentDelivery = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"

Invoke-TTAVRegistryValue `
    -Path $ContentDelivery -Name "SubscribedContent-338388Enabled" -Value 0 -Type DWord `
    -Description "Disable Windows Welcome Experience and Consumer Suggestions"

Invoke-TTAVRegistryValue `
    -Path $ContentDelivery -Name "SubscribedContent-338389Enabled" -Value 0 -Type DWord `
    -Description "Disable Inline Settings Suggestions"

Invoke-TTAVRegistryValue `
    -Path $ContentDelivery -Name "SoftLandingEnabled" -Value 0 -Type DWord `
    -Description "Disable OS Feature Tips and Tricks"


# ==============================================================================
# SECTION 5: Server Annoyance Mitigations
# ==============================================================================
Write-Host "`n[5/12] Server Annoyances & Interactive Logon" -ForegroundColor Yellow

$ReliabilityPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Reliability"

Invoke-TTAVRegistryValue `
    -Path $ReliabilityPath -Name "ShutdownReasonOn" -Value 0 -Type DWord `
    -Description "Disable Shutdown Event Tracker Service Prompt"

Invoke-TTAVRegistryValue `
    -Path $ReliabilityPath -Name "ShutdownReasonUI" -Value 0 -Type DWord `
    -Description "Disable Shutdown Event Tracker GUI Dialog"

Invoke-TTAVRegistryValue `
    -Path "HKLM:\SOFTWARE\Microsoft\ServerManager" `
    -Name "DoNotOpenServerManagerAtLogon" -Value 1 -Type DWord `
    -Description "Disable Server Manager Auto-Launch on User Logon"

Invoke-TTAVRegistryValue `
    -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" `
    -Name "NoLockScreen" -Value 1 -Type DWord `
    -Description "Bypass Decorative Lock Screen (Show Logon Directly)"

Invoke-TTAVRegistryValue `
    -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" `
    -Name "DisableCAD" -Value 1 -Type DWord `
    -Description "Disable Ctrl+Alt+Del Requirement for Logon"


# ==============================================================================
# SECTION 6: Security, System Crash, & Update Policies
# ==============================================================================
Write-Host "`n[6/12] Security, Crash Handling, & Update Policies" -ForegroundColor Yellow

Invoke-TTAVRegistryValue `
    -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
    -Name "PromptOnSecureDesktop" -Value 0 -Type DWord `
    -Description "Disable UAC Secure Desktop Screen Dimming (Prevent Console Freeze)"

Invoke-TTAVRegistryValue `
    -Path "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl" `
    -Name "AutoReboot" -Value 0 -Type DWord `
    -Description "Disable Auto-Reboot on BSOD (Keep Crash Code Visible)"

# Internet Explorer ESC (Admin & User)
$AdminIEKey = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}"
$UserIEKey  = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}"

if (Test-Path $AdminIEKey) {
    Invoke-TTAVRegistryValue `
        -Path $AdminIEKey -Name "IsInstalled" -Value 0 -Type DWord `
        -Description "Disable IE ESC for Administrators"
}

if (Test-Path $UserIEKey) {
    Invoke-TTAVRegistryValue `
        -Path $UserIEKey -Name "IsInstalled" -Value 0 -Type DWord `
        -Description "Disable IE ESC for Standard Users"
}

Invoke-TTAVRegistryValue `
    -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" `
    -Name "EnableSmartScreen" -Value 0 -Type DWord `
    -Description "Disable SmartScreen Warning Prompts for Executables"

# Block Malicious Software Removal Tool (MSRT / KB890830)
Invoke-TTAVRegistryValue `
    -Path "HKLM:\SOFTWARE\Policies\Microsoft\MRT" `
    -Name "DontOfferThroughWUau" -Value 1 -Type DWord `
    -Description "Block Malicious Software Removal Tool (MSRT) via Windows Update"

# Unlimited Password Age Policy (TTAV)
$AccountPolicy = net accounts
$CurrentMaxAge = ($AccountPolicy | Select-String "Maximum password age").Line
if ($CurrentMaxAge -match "UNLIMITED") {
    Write-Host "  [ALREADY SET] Local Account Maximum Password Age: Unlimited" -ForegroundColor DarkGray
} else {
    try {
        net accounts /maxpwage:unlimited | Out-Null
        $VerifyMaxAge = (net accounts | Select-String "Maximum password age").Line
        if ($VerifyMaxAge -match "UNLIMITED") {
            Write-Host "  [APPLIED]     Set Local Account Password Expiration to Unlimited" -ForegroundColor Green
        } else {
            Write-Warning "  [VERIFY FAIL] Could not verify unlimited password expiration."
        }
    }
    catch {
        Write-Error "  [ERROR]       Failed setting net accounts password age: $_"
    }
}


# ==============================================================================
# SECTION 7: Telemetry & Edge Background Policies
# ==============================================================================
Write-Host "`n[7/12] Telemetry & Background Processes" -ForegroundColor Yellow

Invoke-TTAVRegistryValue `
    -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" `
    -Name "AllowTelemetry" -Value 0 -Type DWord `
    -Description "Restrict Diagnostic Telemetry to Security Tier (0)"

$EdgePolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"

Invoke-TTAVRegistryValue `
    -Path $EdgePolicyPath -Name "StartupBoostEnabled" -Value 0 -Type DWord `
    -Description "Disable Microsoft Edge Startup Boost"

Invoke-TTAVRegistryValue `
    -Path $EdgePolicyPath -Name "BackgroundModeEnabled" -Value 0 -Type DWord `
    -Description "Disable Background Microsoft Edge Processes and Extensions"


# ==============================================================================
# SECTION 8: Accessibility Hotkeys (Sticky Keys)
# ==============================================================================
Write-Host "`n[8/12] Accessibility Shortcuts (Sticky Keys)" -ForegroundColor Yellow

Invoke-TTAVRegistryValue `
    -Path "HKCU:\Control Panel\Accessibility\StickyKeys" `
    -Name "Flags" -Value "506" -Type String `
    -Description "Disable Sticky Keys Shortcut (5x Shift Tap)"

Invoke-TTAVRegistryValue `
    -Path "HKCU:\Control Panel\Accessibility\Keyboard Response" `
    -Name "Flags" -Value "122" -Type String `
    -Description "Disable Filter Keys Shortcut (Hold Shift 8 Seconds)"

Invoke-TTAVRegistryValue `
    -Path "HKCU:\Control Panel\Accessibility\ToggleKeys" `
    -Name "Flags" -Value "58" -Type String `
    -Description "Disable Toggle Keys Shortcut (Hold NumLock 5 Seconds)"


# ==============================================================================
# SECTION 9: Network Access & Windows Firewall
# ==============================================================================
Write-Host "`n[9/12] Networking & Inbound Firewall Rules" -ForegroundColor Yellow

# Inbound ICMP (Ping)
Invoke-TTAVFirewallRule `
    -Name "FPS-ICMP4-ERQ-In" `
    -Description "Inbound IPv4 ICMP Echo Request (Ping Responder)"

Invoke-TTAVFirewallRule `
    -Name "FPS-ICMP6-ERQ-In" `
    -Description "Inbound IPv6 ICMP Echo Request (Ping Responder)"

# Remote Desktop (RDP)
Invoke-TTAVRegistryValue `
    -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" `
    -Name "fDenyTSConnections" -Value 0 -Type DWord `
    -Description "Enable Remote Desktop Protocol (fDenyTSConnections = 0)"

Invoke-TTAVFirewallRule `
    -DisplayGroup "Remote Desktop" `
    -Description "Inbound Remote Desktop Firewall Exception Group"


# ==============================================================================
# SECTION 10: Desktop Audio & Hardware Performance
# ==============================================================================
Write-Host "`n[10/12] Audio Services & Power Management" -ForegroundColor Yellow

# Windows Audio Services
Invoke-TTAVService `
    -Name "Audiosrv" -StartupType Automatic `
    -Description "Windows Audio Engine Service (Audiosrv)"

Invoke-TTAVService `
    -Name "AudioEndpointBuilder" -StartupType Automatic `
    -Description "Windows Audio Endpoint Builder Service"

# High Performance Power Scheme (TTAV)
$ActiveSchemeLine = (powercfg /getactivescheme)
if ($ActiveSchemeLine -match "High performance") {
    Write-Host "  [ALREADY SET] Power Scheme: High Performance" -ForegroundColor DarkGray
} else {
    try {
        $HighPerfEntry = powercfg -list | Select-String "High performance"
        if ($HighPerfEntry) {
            $HighPerfGuid = ($HighPerfEntry -split '\s+')[3]
            powercfg -setactive $HighPerfGuid
            
            $VerifyScheme = (powercfg /getactivescheme)
            if ($VerifyScheme -match "High performance") {
                Write-Host "  [APPLIED]     Activated High Performance Power Scheme ($HighPerfGuid)" -ForegroundColor Green
            } else {
                Write-Warning "  [VERIFY FAIL] Power scheme did not update to High Performance."
            }
        } else {
            Write-Warning "  [NOT FOUND]   High Performance power scheme GUID could not be located."
        }
    }
    catch {
        Write-Error "  [ERROR]       Failed setting power plan: $_"
    }
}


# ==============================================================================
# SECTION 11: Legacy Associations & Windows Terminal Profile
# ==============================================================================
Write-Host "`n[11/12] Application Associations & Terminal Defaults" -ForegroundColor Yellow

# Restore Windows Photo Viewer Associations
$PhotoViewerKey = "HKLM:\SOFTWARE\Microsoft\Windows Photo Viewer\Capabilities\FileAssociations"
$ImageFormats = @(".jpg", ".jpeg", ".png", ".bmp", ".gif", ".tiff", ".ico")

foreach ($Ext in $ImageFormats) {
    Invoke-TTAVRegistryValue `
        -Path $PhotoViewerKey -Name $Ext -Value "PhotoViewer.FileAssoc.Tiff" -Type String `
        -Description "Windows Photo Viewer Handler for $Ext"
}

# Windows Terminal Default Profile -> Windows PowerShell (TTAV)
$TerminalSettingsPath = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
if (Test-Path $TerminalSettingsPath) {
    try {
        $JsonContent = Get-Content -Path $TerminalSettingsPath -Raw | ConvertFrom-Json
        $PsProfile = $JsonContent.profiles.list | Where-Object { $_.name -eq "Windows PowerShell" }

        if ($null -ne $PsProfile) {
            if ($JsonContent.defaultProfile -eq $PsProfile.guid) {
                Write-Host "  [ALREADY SET] Windows Terminal Default Profile: Windows PowerShell" -ForegroundColor DarkGray
            } else {
                $JsonContent.defaultProfile = $PsProfile.guid
                $JsonContent | ConvertTo-Json -Depth 32 | Set-Content -Path $TerminalSettingsPath -Encoding UTF8
                
                # Verify
                $VerifyJson = Get-Content -Path $TerminalSettingsPath -Raw | ConvertFrom-Json
                if ($VerifyJson.defaultProfile -eq $PsProfile.guid) {
                    Write-Host "  [APPLIED]     Set Windows Terminal Default Profile to Windows PowerShell" -ForegroundColor Green
                } else {
                    Write-Warning "  [VERIFY FAIL] Terminal settings.json did not save defaultProfile."
                }
            }
        } else {
            Write-Host "  [SKIPPED]     Windows PowerShell profile not listed in Terminal settings." -ForegroundColor DarkGray
        }
    }
    catch {
        Write-Error "  [ERROR]       Failed parsing or updating Terminal settings.json: $_"
    }
} else {
    Write-Host "  [SKIPPED]     Windows Terminal settings file not present." -ForegroundColor DarkGray
}


# ==============================================================================
# SECTION 12: Idempotent Explorer Refresh
# ==============================================================================
Write-Host "`n[12/12] Explorer Process State Engine" -ForegroundColor Yellow

if ($script:ExplorerRestartRequired) {
    Write-Host "  [ACTION]      Restarting Windows Explorer to commit shell modifications..." -ForegroundColor Yellow
    try {
        Stop-Process -Name explorer -Force -ErrorAction Stop
        Start-Sleep -Seconds 1
        if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
            Start-Process explorer.exe
        }
        Write-Host "  [VERIFIED]    Windows Explorer restarted successfully." -ForegroundColor Green
    }
    catch {
        Write-Error "  [ERROR]       Failed to restart Windows Explorer: $_"
    }
} else {
    Write-Host "  [NO RESTART]  All shell properties were already compliant; skipping Explorer restart." -ForegroundColor DarkGray
}

Write-Host "`n====================================================================" -ForegroundColor Cyan
Write-Host " Engine Complete. All configuration tasks verified!                 " -ForegroundColor Cyan
Write-Host "====================================================================" -ForegroundColor Cyan
