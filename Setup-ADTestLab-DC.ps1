#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Turns a fresh Windows Server into the adetest.local domain controller and seeds
  it with the test users, computers and groups ADE is tested against.

.DESCRIPTION
  Run it on a clean Windows Server 2025 VM (also works on 2019/2022). It is
  stage-aware and safe to re-run - run it again after each reboot it asks for.
  On 2025 the new forest defaults to the Win2025 functional level, which is
  fine for ADE and for a throwaway lab.

    Run 1: renames the server to DC1 (if needed) and reboots.
    Run 2: sets the local Administrator password (which becomes the domain
           Administrator password), installs AD DS, promotes the server to a
           domain controller for adetest.local (auto-reboots).
    Run 3: seeds the test OUs, users, computers and groups, then prints a summary.

  Seeded objects (OU=Lab / Users, Computers, Groups):
    alice.admin      normal user (Lab Admins + Help Desk)
    bob.user         normal user; primary group = PrimaryOnly (see below)
    carol.locked     locked out (lockoutTime set to now)
    dave.disabled    disabled account
    erin.expired     must change password at next logon (pwdLastSet = 0)
    frank.stale      never logged on -> stale
    henry.never      never logged on -> stale
    svc.backup       "DO NOT DELETE - backup service account", password never expires
    HealthMailbox01  Exchange-style name ADE's quick delete must refuse
    WS-001 / WS-OLD / SRV-001 / SRV-OLD   computer objects with OS attributes
    Lab Admins, Help Desk, Empty Group, Protected Group (DO NOT DELETE),
    PrimaryOnly - zero member entries, but it is bob.user's primaryGroupID:
    the exact case ADE's empty-group recheck exists for.

  NOTE on "stale/current": Microsoft AD owns lastLogonTimestamp - no script can
  write it. Stale here means what it means in production: the account has never
  logged on (or not within the threshold). alice.admin/bob.user get a real
  "current" logon the first time someone signs in as them (e.g. on the joined
  workstation VM). The computer objects are unjoined placeholders, so AD shows
  them as never-logged-on until a machine with that name actually joins.

.EXAMPLE
  .\Setup-ADTestLab-DC.ps1
  .\Setup-ADTestLab-DC.ps1 -ServerIP 192.168.250.10 -Gateway 192.168.250.1 -DnsForwarder 1.1.1.1
#>
[CmdletBinding()]
param(
    [string]$DomainName    = 'adetest.local',
    [string]$NetbiosName   = 'ADETEST',
    [string]$DcName        = 'DC1',
    [string]$AdminPassword = 'LabAdmin!2026',   # local admin now -> domain admin after promotion; also DSRM
    [string]$UserPassword  = 'LabPass1!',       # every seeded user
    [string]$ServerIP,                          # optional: set a static IP first
    [int]   $PrefixLength  = 24,
    [string]$Gateway,                           # optional
    [string]$DnsForwarder                       # optional: upstream DNS for the DC
)

$ErrorActionPreference = 'Stop'

function Test-IsDomainController {
    if (-not (Get-Module -ListAvailable ActiveDirectory)) { return $false }
    try { $null = Get-ADDomain -ErrorAction Stop; return $true } catch { return $false }
}

# =============================== SEED STAGE ===================================
function Invoke-LabSeed {
    Write-Host "Waiting for Active Directory to answer..." -ForegroundColor Cyan
    $deadline = (Get-Date).AddMinutes(3)
    while (-not (Test-IsDomainController)) {
        if ((Get-Date) -gt $deadline) { throw "AD did not become ready within 3 minutes. Re-run the script in a few minutes." }
        Start-Sleep -Seconds 10
    }
    Import-Module ActiveDirectory
    $dn   = (Get-ADDomain).DistinguishedName
    $upn  = $DomainName
    $ouLab = "OU=Lab,$dn"; $ouUsers = "OU=Users,$ouLab"; $ouPc = "OU=Computers,$ouLab"; $ouGrp = "OU=Groups,$ouLab"

    function Ensure-OU([string]$Name, [string]$Path) {
        if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$Name'" -SearchBase $Path -ErrorAction SilentlyContinue)) {
            New-ADOrganizationalUnit -Name $Name -Path $Path | Out-Null
            Write-Host "  OU created: $Name"
        }
    }
    Ensure-OU 'Lab' $dn; Ensure-OU 'Users' $ouLab; Ensure-OU 'Computers' $ouLab; Ensure-OU 'Groups' $ouLab

    $pw = ConvertTo-SecureString $UserPassword -AsPlainText -Force
    function Ensure-User([string]$Sam, [string]$Given, [string]$Sur, [hashtable]$Extra = @{}) {
        if (Get-ADUser -Filter "SamAccountName -eq '$Sam'" -ErrorAction SilentlyContinue) {
            Write-Host "  user exists, skipping create: $Sam"; return
        }
        $uArgs = @{
            SamAccountName = $Sam; GivenName = $Given; Surname = $Sur
            Name = "$Given $Sur"; DisplayName = "$Given $Sur"
            UserPrincipalName = "$Sam@$upn"; Path = $ouUsers
            AccountPassword = $pw; Enabled = $true
        }
        foreach ($k in $Extra.Keys) { $uArgs[$k] = $Extra[$k] }
        New-ADUser @uArgs
        Write-Host "  user created: $Sam"
    }

    Write-Host "Seeding users (password for all: $UserPassword)..." -ForegroundColor Cyan
    Ensure-User 'alice.admin'     'Alice'  'Admin'
    Ensure-User 'bob.user'        'Bob'    'User'
    Ensure-User 'carol.locked'    'Carol'  'Locked'
    Ensure-User 'dave.disabled'   'Dave'   'Disabled'
    Ensure-User 'erin.expired'    'Erin'   'Expired'
    Ensure-User 'frank.stale'     'Frank'  'Stale'
    Ensure-User 'henry.never'     'Henry'  'Never'
    Ensure-User 'svc.backup'      'Backup' 'Service' @{ Description = 'DO NOT DELETE - backup service account'; PasswordNeverExpires = $true }
    Ensure-User 'HealthMailbox01' 'Health' 'Mailbox'

    # Special states (all idempotent - applied every run)
    Disable-ADAccount -Identity 'dave.disabled'
    Set-ADUser -Identity 'erin.expired' -ChangePasswordAtLogon $true
    try {
        Set-ADUser -Identity 'carol.locked' -Replace @{ lockoutTime = [DateTime]::UtcNow.ToFileTimeUtc() }
    } catch { Write-Warning "Could not set lockoutTime on carol.locked: $($_.Exception.Message)" }
    $carol = Get-ADUser 'carol.locked' -Properties LockedOut
    Write-Host "  carol.locked LockedOut = $($carol.LockedOut) (should be True)"

    Write-Host "Seeding computers..." -ForegroundColor Cyan
    $pcs = @(
        @{ Name = 'WS-001';  OS = 'Windows 11 Pro';                   Ver = '10.0 (22631)' }
        @{ Name = 'WS-OLD';  OS = 'Windows 10 Pro';                   Ver = '10.0 (19045)' }
        @{ Name = 'SRV-001'; OS = 'Windows Server 2022 Datacenter';   Ver = '10.0 (20348)' }
        @{ Name = 'SRV-OLD'; OS = 'Windows Server 2016 Standard';     Ver = '10.0 (14393)' }
    )
    foreach ($pc in $pcs) {
        if (Get-ADComputer -Filter "Name -eq '$($pc.Name)'" -ErrorAction SilentlyContinue) {
            Write-Host "  computer exists, skipping: $($pc.Name)"; continue
        }
        New-ADComputer -Name $pc.Name -Path $ouPc -OperatingSystem $pc.OS `
                       -OperatingSystemVersion $pc.Ver -Enabled $true
        Write-Host "  computer created: $($pc.Name)"
    }

    Write-Host "Seeding groups..." -ForegroundColor Cyan
    function Ensure-Group([string]$Name, [string]$Desc) {
        if (Get-ADGroup -Filter "Name -eq '$Name'" -ErrorAction SilentlyContinue) {
            Write-Host "  group exists, skipping create: $Name"; return
        }
        New-ADGroup -Name $Name -SamAccountName $Name -GroupCategory Security `
                    -GroupScope Global -Path $ouGrp -Description $Desc
        Write-Host "  group created: $Name"
    }
    Ensure-Group 'Lab Admins'      'Lab administrators'
    Ensure-Group 'Help Desk'       ''
    Ensure-Group 'Empty Group'     'No members - safe to delete in tests'
    Ensure-Group 'Protected Group' 'DO NOT DELETE - vendor managed'
    Ensure-Group 'PrimaryOnly'     "Exists only as bob.user's primary group"
    Add-ADGroupMember -Identity 'Lab Admins' -Members 'alice.admin', 'bob.user' -ErrorAction SilentlyContinue
    Add-ADGroupMember -Identity 'Help Desk'  -Members 'alice.admin' -ErrorAction SilentlyContinue

    # PrimaryOnly: bob.user's primary group, with ZERO member entries (the H8 case).
    $rid = ((Get-ADGroup 'PrimaryOnly').SID.Value -split '-')[-1]
    Set-ADUser -Identity 'bob.user' -Replace @{ primaryGroupID = [int]$rid }
    $bob = Get-ADUser 'bob.user' -Properties PrimaryGroupID
    $memberCount = @(Get-ADGroupMember -Identity 'PrimaryOnly').Count
    Write-Host "  bob.user PrimaryGroupID = $($bob.PrimaryGroupID) (PrimaryOnly RID $rid); PrimaryOnly member count = $memberCount (should be 0)"

    if ($DnsForwarder) {
        try {
            Import-Module DnsServer -ErrorAction Stop
            Add-DnsServerForwarder -IPAddress $DnsForwarder -ErrorAction SilentlyContinue
            Write-Host "  DNS forwarder set: $DnsForwarder"
        } catch { Write-Warning "Could not set DNS forwarder: $($_.Exception.Message)" }
    }

    Write-Host ""
    Write-Host "==============================================================" -ForegroundColor Green
    Write-Host " adetest.local lab is SEEDED" -ForegroundColor Green
    Write-Host "==============================================================" -ForegroundColor Green
    Write-Host " Domain admin : $NetbiosName\Administrator / $AdminPassword"
    Write-Host " Seeded users : alice.admin, bob.user, carol.locked, dave.disabled,"
    Write-Host "                erin.expired, frank.stale, henry.never, svc.backup,"
    Write-Host "                HealthMailbox01 - all passwords $UserPassword"
    Write-Host " Next: run Join-ADTestLab.ps1 on your workstation VM (point its DNS"
    Write-Host " at this server first), sign in once as $NetbiosName\alice.admin to"
    Write-Host " give her a real current logon, then run ADE on that VM."
}

# ============================ PROMOTION STAGE =================================
if (Test-IsDomainController) {
    Invoke-LabSeed
    exit 0
}

Write-Host "== ADE test lab - domain controller setup ==" -ForegroundColor Cyan

if ($env:COMPUTERNAME -ne $DcName) {
    Write-Host "Renaming this server to $DcName and rebooting. Run the script again after the reboot." -ForegroundColor Yellow
    Rename-Computer -NewName $DcName -Force
    Start-Sleep -Seconds 5
    Restart-Computer -Force
    exit 0
}

if ($ServerIP) {
    $nic = Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -First 1
    if (-not $nic) { throw "No active physical network adapter found for static IP setup." }
    $current = Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
               Where-Object IPAddress -notlike '169.254*'
    if (-not $current -or $current.IPAddress -ne $ServerIP) {
        Write-Host "Setting static IP $ServerIP/$PrefixLength on '$($nic.Name)'..." -ForegroundColor Cyan
        $current | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        $ipArgs = @{ InterfaceIndex = $nic.ifIndex; IPAddress = $ServerIP; PrefixLength = $PrefixLength }
        if ($Gateway) { $ipArgs.DefaultGateway = $Gateway }
        New-NetIPAddress @ipArgs | Out-Null
    }
    Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses '127.0.0.1'
}

Write-Host "Setting local Administrator password (becomes the domain admin password)..." -ForegroundColor Cyan
try {
    $sec = ConvertTo-SecureString $AdminPassword -AsPlainText -Force
    Set-LocalUser -Name 'Administrator' -Password $sec
    Enable-LocalUser -Name 'Administrator' -ErrorAction SilentlyContinue
} catch { Write-Warning "Could not set the local Administrator password: $($_.Exception.Message). The domain Administrator will keep whatever password this server already has." }

Write-Host "Installing AD DS role..." -ForegroundColor Cyan
$feat = Install-WindowsFeature AD-Domain-Services -IncludeManagementTools
if ($feat.RestartNeeded -eq 'Yes') {
    Write-Host "A reboot is needed before promotion. Reboot, then run the script again." -ForegroundColor Yellow
    exit 0
}

Write-Host "Promoting to domain controller for $DomainName (server reboots automatically)..." -ForegroundColor Cyan
Write-Host "After the reboot, log in and run this script ONE more time to seed the test objects." -ForegroundColor Yellow
Import-Module ADDSDeployment
Install-ADDSForest `
    -DomainName $DomainName `
    -DomainNetbiosName $NetbiosName `
    -SafeModeAdministratorPassword (ConvertTo-SecureString $AdminPassword -AsPlainText -Force) `
    -InstallDNS `
    -CreateDnsDelegation:$false `
    -Force
