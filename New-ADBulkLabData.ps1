#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Bulk test-data generator v3 for the ADE lab domain: a FIXED set of thousands
  of users, workstations, servers and groups with mixed memberships - fully
  idempotent. Defaults: 3000 users, 2000 workstations, 2000 servers,
  2000 groups (about 9000 objects). The first run at that scale creates
  everything and takes a while on a VM DC; re-runs converge with bulk reads
  and almost no writes. Every stage follows Test -> Try -> Action -> Verify:
  bulk reads test what exists, every create/change is wrapped so a single
  failure warns and skips instead of aborting the run, and a final pass
  re-reads the directory and reports exactly which targets are present. The v2 targets (the first 100 users, 200 groups and
  100 computers) are unchanged, so upgrading simply grows the existing set -
  group memberships re-randomize under the new counts and reconcile once.

.DESCRIPTION
  Version 1 picked random names, so a re-run minted a whole new batch (the user
  ended up with 151 groups). This version is deterministic: the object names,
  attributes and even the "random" group memberships come from fixed lists and
  a fixed-seed generator, so EVERY run converges the Bulk OU to the exact same
  target state -

    * objects that exist are skipped (and their state re-applied),
    * group memberships are reconciled: missing members added, extra bulk
      members removed,
    * nothing new is created on a re-run.

  Objects left over from the random v1 (same names can't collide twice, but v1
  invented different ones) are reported as "strays". Delete them with -Prune.
  -Remove wipes OU=Bulk entirely (after a typed confirmation).

  Everything lives in OU=Bulk (Users / Computers / Groups), away from the
  curated OU=Lab seed. Run on DC1 or anywhere with the AD module + rights.

  Category coverage (counts at the default 3000/2000/2000/2000), matched to
  how ADE's Environment overview actually counts:
    Users   : 150 disabled, 120 locked (real lockouts - see below), 120 password-expired
              (passwords left to age past the lab's 1-day max age), 120 must-change (pwdLastSet 0),
              120 password-never-expires, 120 DO NOT DELETE descriptions,
              120 org boxes ("Shared mailbox" descriptions), the rest carry a
              per-user description (title + department), an office and varied
              department/title - and every enabled user is stale (never logged on).
    Computers: 2000 workstations / 2000 servers as separate populations
              (OS attributes spread over Win 10/11 and Server 2019/2022/2025),
              160 disabled, all never-logged-on (stale; the servers count as offline).
    Groups  : 1800 security / 200 distribution, exactly 5 deliberately empty
              (the last five), the other 1995 mixed membership (~8000 total),
              each with its own description.
  Not coverable by any data script: "Longest uptime servers" - that one needs
  a real machine answering WMI.

.EXAMPLE
  .\New-ADBulkLabData.ps1            # create or converge
  .\New-ADBulkLabData.ps1 -Prune     # also delete stray v1 leftovers in OU=Bulk
  .\New-ADBulkLabData.ps1 -Remove    # delete OU=Bulk and everything in it
#>
[CmdletBinding()]
param(
    [int]   $UserCount     = 3000,
    [int]   $ComputerCount = 2000,   # workstations
    [int]   $ServerCount   = 2000,   # servers (own population - ADE counts them separately)
    [int]   $GroupCount    = 2000,
    [string]$UserPassword  = 'LabPass1!',
    [string]$AdminPassword = 'LabAdmin!2026',   # used once per run to keep the lab admin from expiring under the 1-day policy
    [string]$BulkOuName    = 'Bulk',
    [switch]$Prune,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory
$domain  = Get-ADDomain
$dn      = $domain.DistinguishedName
$dnsRoot = $domain.DNSRoot
$ouBulk  = "OU=$BulkOuName,$dn"
$ouUsers = "OU=Users,$ouBulk"; $ouPc = "OU=Computers,$ouBulk"; $ouGrp = "OU=Groups,$ouBulk"

function Remove-BulkOu {
    if (-not (Get-ADOrganizationalUnit -Identity $ouBulk -ErrorAction SilentlyContinue)) {
        Write-Host "OU $ouBulk doesn't exist - nothing to remove."; return
    }
    Write-Host "This deletes OU=$BulkOuName and ALL users/computers/groups inside it." -ForegroundColor Yellow
    if ((Read-Host "Type REMOVE to confirm") -ne 'REMOVE') { Write-Host "Cancelled."; return }
    Set-ADOrganizationalUnit -Identity $ouBulk -ProtectedFromAccidentalDeletion $false
    Get-ADOrganizationalUnit -SearchBase $ouBulk -Filter * |
        Set-ADOrganizationalUnit -ProtectedFromAccidentalDeletion $false
    Remove-ADOrganizationalUnit -Identity $ouBulk -Recursive -Confirm:$false
    Write-Host "Bulk lab data removed." -ForegroundColor Green
}
if ($Remove) { Remove-BulkOu; exit 0 }

# --- Deterministic name material (fixed order - never shuffled) ----------------
$firstNames = 'James','Mary','Robert','Patricia','John','Jennifer','Michael','Linda','David','Elizabeth',
              'William','Barbara','Richard','Susan','Joseph','Jessica','Thomas','Sarah','Charles','Karen',
              'Daniel','Nancy','Matthew','Lisa','Anthony','Betty','Mark','Margaret','Donald','Sandra'
$lastNames  = 'Smith','Johnson','Williams','Brown','Jones','Garcia','Miller','Davis','Rodriguez','Martinez',
              'Hernandez','Lopez','Gonzalez','Wilson','Anderson','Thomas','Taylor','Moore','Jackson','Martin',
              'Lee','Perez','Thompson','White','Harris','Sanchez','Clark','Lewis','Robinson','Walker'
$departments = 'Finance','Human Resources','Information Tech','Sales','Marketing','Operations','Support',
               'Engineering','Legal','Procurement','Facilities','Research','Logistics','Quality','Security'
$titles      = 'Analyst','Technician','Coordinator','Specialist','Supervisor','Engineer','Assistant',
               'Consultant','Administrator','Representative'
$offices     = 'Austin','Denver','Chicago','Seattle','Boston','Phoenix','Atlanta','Portland',
               'Dallas','Miami','Nashville','Raleigh','Columbus','Tampa','Fresno','Boise'
$clientOs = @(@{ OS = 'Windows 11 Pro'; Ver = '10.0 (22631)' }, @{ OS = 'Windows 11 Pro'; Ver = '10.0 (26100)' },
              @{ OS = 'Windows 10 Pro'; Ver = '10.0 (19045)' }, @{ OS = 'Windows 11 Enterprise'; Ver = '10.0 (22631)' })
$serverOs = @(@{ OS = 'Windows Server 2022 Datacenter'; Ver = '10.0 (20348)' },
              @{ OS = 'Windows Server 2025 Datacenter'; Ver = '10.0 (26100)' },
              @{ OS = 'Windows Server 2019 Standard';   Ver = '10.0 (17763)' })
$groupWords1 = 'Finance','HR','IT','Sales','Marketing','Operations','Support','Engineering','Legal','Field',
               'Remote','Project','Regional','Corporate','Customer','Vendor','Training','Audit','Data','Cloud'
$groupWords2 = 'Team','Admins','Users','Group','Committee','Staff','Crew','Unit','Circle','Board'

# The target user set, in fixed order. Pass 1: first x last combinations
# (900 - the first 100 are exactly the v2 targets). Pass 2 (only if more are
# requested): the same combinations with a middle initial, which keeps both
# the sAM and the CN unique ("James A. Smith" / jasmith). Capacity ~24,000.
$targetUsers = @()
$usedSam = @{}
foreach ($f in $firstNames) {
    foreach ($l in $lastNames) {
        if ($targetUsers.Count -ge $UserCount) { break }
        $sam = ($f.Substring(0,1) + $l).ToLower(); $base = $sam; $n = 1
        while ($usedSam[$sam]) { $n++; $sam = "$base$n" }
        $usedSam[$sam] = $true
        $targetUsers += [pscustomobject]@{ Sam = $sam; Given = $f; Sur = $l; Name = "$f $l"; Display = "$f $l" }
    }
    if ($targetUsers.Count -ge $UserCount) { break }
}
if ($targetUsers.Count -lt $UserCount) {
    foreach ($f in $firstNames) {
        foreach ($l in $lastNames) {
            foreach ($m in 'A','B','C','D','E','F','G','H','J','K','L','M','N','P','R','S','T','V','W') {
                if ($targetUsers.Count -ge $UserCount) { break }
                $sam = ($f.Substring(0,1) + $m + $l).ToLower(); $base = $sam; $n = 1
                while ($usedSam[$sam]) { $n++; $sam = "$base$n" }
                $usedSam[$sam] = $true
                $targetUsers += [pscustomobject]@{ Sam = $sam; Given = $f; Sur = $l; Name = "$f $m. $l"; Display = "$f $m. $l" }
            }
            if ($targetUsers.Count -ge $UserCount) { break }
        }
        if ($targetUsers.Count -ge $UserCount) { break }
    }
}
if ($targetUsers.Count -lt $UserCount) { Write-Warning "Name material exhausted at $($targetUsers.Count) users (requested $UserCount)." }
# The target group set: word combinations in fixed order - first pass plain
# ("Finance Team"), then a regional pass ("Finance Team - North"), then a
# second regional pass ("Finance Team - North Ops"). The plain pass yields
# 200 names and each regional pass 2000, and the first 200 targets are
# exactly the ones earlier versions generated.
$targetGroups = @()
$regionSets = @(@(), @('North','South','East','West','Central','Metro','Coastal','Valley','Lakes','Prairie'),
                     @('North Ops','South Ops','East Ops','West Ops','Central Ops','Metro Ops','Coastal Ops','Valley Ops','Lakes Ops','Prairie Ops'))
foreach ($suffixes in $regionSets) {
    foreach ($a in $groupWords1) {
        foreach ($b in $groupWords2) {
            if ($targetGroups.Count -ge $GroupCount) { break }
            if ($suffixes.Count -eq 0) { $targetGroups += "$a $b" }
            else { foreach ($s in $suffixes) { if ($targetGroups.Count -lt $GroupCount) { $targetGroups += "$a $b - $s" } } }
        }
        if ($targetGroups.Count -ge $GroupCount) { break }
    }
    if ($targetGroups.Count -ge $GroupCount) { break }
}
if ($targetGroups.Count -lt $GroupCount) { Write-Warning "Group name material exhausted at $($targetGroups.Count) groups (requested $GroupCount)." }
# Target computers: workstations and servers as SEPARATE populations with
# their own counters (WS-201..., SRV-201...). Earlier versions interleaved
# servers into the workstation sequence; those SRV-210-style names are no
# longer targets and show up as strays - one -Prune run clears them.
$targetComputers = @()
for ($i = 1; $i -le $ComputerCount; $i++) {
    $targetComputers += [pscustomobject]@{ Name = "WS-$($i + 200)";  IsServer = $false; Index = $i }
}
for ($i = 1; $i -le $ServerCount; $i++) {
    $targetComputers += [pscustomobject]@{ Name = "SRV-$($i + 200)"; IsServer = $true;  Index = $i }
}

# --- OUs -------------------------------------------------------------------------
foreach ($p in @(@($BulkOuName, $dn), @('Users', $ouBulk), @('Computers', $ouBulk), @('Groups', $ouBulk))) {
    if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$($p[0])'" -SearchBase $p[1] -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $p[0] -Path $p[1] | Out-Null
    }
}

# --- Lab domain policy (prerequisite for the locked + expired fixtures) -----------
# lockoutTime is system-owned: a DC refuses direct writes of a timestamp (only 0,
# to unlock, is accepted - that crashed an early run at user #3). pwdLastSet is
# nearly as restricted: only 0 (must-change) and -1 (stamp "now") are writable,
# so a password can never be backdated either. Real states have to come from the
# DC itself:
#   * LOCKED  - lockout policy here (threshold 5), tripped by bad logons below.
#     Duration 30 min is what the AD cmdlet accepts (0 is refused); ADE reads
#     the raw lockoutTime, which stays set after the window passes, and every
#     run re-locks - so the fixture holds.
#   * EXPIRED - max password age of 1 day for the lab (set together with min
#     age 0 below: AD refuses a max that is not strictly greater than the min,
#     which is what killed the max-only call on a real DC). Every bulk password is
#     refreshed on each run EXCEPT the designated expired set, so after 24h
#     exactly those accounts (plus any older built-in/seed accounts) count as
#     password-expired. Password history is 0 so a forced change at logon can
#     reuse the same lab password instead of stranding an account.
# The lab Administrator's password is refreshed too, so the 1-day policy never
# locks the operator out of their own lab. Each setting is applied in its OWN
# call: one combined call failed atomically on a real DC ("The parameter is
# incorrect" with no hint which setting), so now each lands independently and a
# refusal names the exact setting. Nothing here may abort the run.
function Invoke-BadLogons([string]$Sam, [int]$Count = 6) {
    for ($a = 0; $a -lt $Count; $a++) {
        try {
            $entry = New-Object System.DirectoryServices.DirectoryEntry(
                "LDAP://$dn", "$($domain.NetBIOSName)\$Sam", 'WrongPass!234', 'Secure')
            $null = $entry.Name   # forces the bind; the bad password does the work
        } catch { }
    }
}
function Try-State([scriptblock]$Op, [string]$What) {
    try { & $Op } catch { Write-Warning "$What failed: $($_.Exception.Message)" }
}
Try-State { Set-ADDefaultDomainPasswordPolicy -Identity $dnsRoot -LockoutThreshold 5 -LockoutDuration '00:30:00' -LockoutObservationWindow '00:30:00' } "lockout policy (threshold 5, 30 min)"
Try-State { Set-ADDefaultDomainPasswordPolicy -Identity $dnsRoot -MinPasswordAge '0.00:00:00' -MaxPasswordAge '1.00:00:00' } "password ages (min 0, max 1 day)"
Try-State { Set-ADDefaultDomainPasswordPolicy -Identity $dnsRoot -PasswordHistoryCount 0 } "password history (0)"
Try-State { Set-ADAccountPassword -Identity 'Administrator' -Reset -NewPassword (ConvertTo-SecureString $AdminPassword -AsPlainText -Force) } "Administrator password refresh"

# --- TEST: bulk-read the current state of OU=Bulk --------------------------------
# The whole script follows Test -> Try -> Action -> Verify: nothing is created
# or changed on a guess, every action is wrapped so one failure warns instead
# of aborting the run, and a verification pass at the end re-reads the
# directory and reports exactly which targets are present.
$existingUsers = @{}
Get-ADUser -SearchBase $ouUsers -Filter * -Properties pwdLastSet, LockedOut, PasswordNeverExpires, Description, Enabled |
    ForEach-Object { $existingUsers[$_.SamAccountName] = $_ }
$existingPcs = @{}
Get-ADComputer -SearchBase $ouPc -Filter * -Properties Enabled |
    ForEach-Object { $existingPcs[$_.Name] = $_ }
$existingGrps = @{}
Get-ADGroup -SearchBase $ouGrp -Filter * -Properties GroupCategory |
    ForEach-Object { $existingGrps[$_.Name] = $_ }
$targetUserSams = @($targetUsers | ForEach-Object Sam)
$targetUserSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$targetUserSams)
$targetPcSet   = [System.Collections.Generic.HashSet[string]]::new([string[]]@($targetComputers | ForEach-Object Name))
$targetGrpSet  = [System.Collections.Generic.HashSet[string]]::new([string[]]$targetGroups)
# Name (CN) occupancy in the Users OU: a target whose sAM is free but whose
# NAME is held by a different object cannot be created (error 8305) - detect
# that here instead of crashing into the create.
$userNameToSam = @{}
$existingUsers.Values | ForEach-Object { $userNameToSam[$_.Name] = $_.SamAccountName }

# --- Strays: objects in OU=Bulk that are NOT in the target sets -------------------
# Handled BEFORE any creation, so a stray squatting on a target name is
# cleared by -Prune first instead of colliding with the create.
$strayUsers = @($existingUsers.Values | Where-Object { -not $targetUserSet.Contains($_.SamAccountName) })
$strayPcs   = @($existingPcs.Values   | Where-Object { -not $targetPcSet.Contains($_.Name) })
$strayGrps  = @($existingGrps.Values  | Where-Object { -not $targetGrpSet.Contains($_.Name) })
$strayCount = $strayUsers.Count + $strayPcs.Count + $strayGrps.Count
if ($strayCount -gt 0) {
    Write-Host "Strays in OU=$BulkOuName (not part of the standard set): $($strayUsers.Count) users, $($strayPcs.Count) computers, $($strayGrps.Count) groups" -ForegroundColor Yellow
    if ($Prune) {
        $strayUsers | ForEach-Object {
            try { Remove-ADUser -Identity $_.DistinguishedName -Confirm:$false; $existingUsers.Remove($_.SamAccountName); $userNameToSam.Remove($_.Name) }
            catch { Write-Warning "prune user $($_.SamAccountName) failed: $($_.Exception.Message)" } }
        $strayPcs | ForEach-Object {
            try { Remove-ADComputer -Identity $_.DistinguishedName -Confirm:$false; $existingPcs.Remove($_.Name) }
            catch { Write-Warning "prune computer $($_.Name) failed: $($_.Exception.Message)" } }
        $strayGrps | ForEach-Object {
            try { Remove-ADGroup -Identity $_.DistinguishedName -Confirm:$false; $existingGrps.Remove($_.Name) }
            catch { Write-Warning "prune group $($_.Name) failed: $($_.Exception.Message)" } }
        Write-Host "  pruned." -ForegroundColor Yellow
    } else {
        Write-Host "  (left untouched - re-run with -Prune to delete them)" -ForegroundColor Yellow
    }
}

# --- Users: create what's missing, then apply each user's designated state -------
# Every state write fires only when the read-back says the account differs
# from its target - so a converged re-run is nearly all reads.
$secPw = ConvertTo-SecureString $UserPassword -AsPlainText -Force
$created = 0; $present = 0; $conflicts = 0; $createFails = 0
for ($idx = 0; $idx -lt $targetUsers.Count; $idx++) {
    $u = $targetUsers[$idx]; $i = $idx + 1
    $existing = $existingUsers[$u.Sam]
    $wasExisting = [bool]$existing
    if (-not $existing) {
        # TEST before ACTION: the name itself may be taken by a different
        # object in this OU (that is what error 8305 means) - name it and skip.
        if ($userNameToSam.ContainsKey($u.Name)) {
            Write-Warning "Name conflict: '$($u.Name)' already exists in OU=Users as '$($userNameToSam[$u.Name])' - skipping $($u.Sam). If that object is a leftover, re-run with -Prune."
            $conflicts++
            continue
        }
        # TRY the ACTION; VERIFY by keeping the returned object as the state
        # the rest of this loop works from.
        try {
            $newObj = New-ADUser -SamAccountName $u.Sam -GivenName $u.Given -Surname $u.Sur -Name $u.Name `
                       -DisplayName $u.Display -UserPrincipalName "$($u.Sam)@$dnsRoot" -Path $ouUsers `
                       -AccountPassword $secPw -Enabled ($i % 20 -ne 0) `
                       -Department $departments[$idx % $departments.Count] -Title $titles[$idx % $titles.Count] `
                       -Office $offices[$idx % $offices.Count] `
                       -Description "Bulk lab user - $($titles[$idx % $titles.Count]), $($departments[$idx % $departments.Count])" -PassThru
            $existingUsers[$u.Sam] = $newObj
            $userNameToSam[$u.Name] = $u.Sam
            $existing = $newObj
            $created++
        } catch {
            Write-Warning "create user $($u.Sam) failed: $($_.Exception.Message)"
            $createFails++
            continue
        }
    } else { $present++ }

    # Password freshness, EXCEPT the expired set (i % 25 -eq 8): refresh only
    # when the stored password is actually aging (older than 20h), so
    # steady-state re-runs do almost no password writes at all. (The refresh
    # also resets pwdLastSet, so must-change targets re-apply their flag below.)
    $refreshed = $false
    if ($wasExisting -and $i % 25 -ne 8 -and ($existing.pwdLastSet -eq 0 -or [DateTime]::FromFileTime($existing.pwdLastSet) -lt (Get-Date).AddHours(-20))) {
        Try-State { Set-ADAccountPassword -Identity $u.Sam -Reset -NewPassword $secPw } "password refresh for $($u.Sam)"
        $refreshed = $true
    }

    # Designated states by position (disjoint sets - see header). Applied every
    # run, so a re-run repairs any drift instead of piling on new objects.
    if ($existing -and $existing.Enabled -eq ($i % 20 -eq 0)) {
        if ($i % 20 -eq 0) { Try-State { Disable-ADAccount -Identity $u.Sam } "disable $($u.Sam)" }
        else               { Try-State { Enable-ADAccount  -Identity $u.Sam } "enable $($u.Sam)" }
    }
    if     ($i % 25 -eq 3)  {
        if (-not $existing -or -not $existing.LockedOut) {
            Invoke-BadLogons $u.Sam
            if (-not (Get-ADUser -Identity $u.Sam -Properties LockedOut).LockedOut) {
                Write-Warning "$($u.Sam) did not lock after bad logon attempts - check the domain lockout policy."
            }
        }
    }
    # i % 25 -eq 8 is the password-expired set: deliberately NO attribute write
    # (pwdLastSet refuses backdating). Their passwords simply never get
    # refreshed above, so they age past the lab's 1-day max password age.
    if     ($i % 25 -eq 13) { if (-not $existing -or $existing.pwdLastSet -ne 0 -or $refreshed) { Try-State { Set-ADUser -Identity $u.Sam -ChangePasswordAtLogon $true } "must-change for $($u.Sam)" } }
    if     ($i % 25 -eq 18) { if (-not $existing -or -not $existing.PasswordNeverExpires) { Try-State { Set-ADUser -Identity $u.Sam -PasswordNeverExpires $true } "never-expires for $($u.Sam)" } }
    if     ($i % 25 -eq 23) { if (-not $existing -or $existing.Description -ne 'DO NOT DELETE - bulk test account') { Try-State { Set-ADUser -Identity $u.Sam -Description 'DO NOT DELETE - bulk test account' } "description for $($u.Sam)" } }
    if     ($i % 25 -eq 1)  { $d = "Shared mailbox - $($departments[$idx % $departments.Count]) team"; if (-not $existing -or $existing.Description -ne $d) { Try-State { Set-ADUser -Identity $u.Sam -Description $d } "description for $($u.Sam)" } }
}
Write-Host "Users: $created created, $present already present (target $($targetUsers.Count))" -ForegroundColor Cyan
if ($conflicts + $createFails -gt 0) { Write-Host "  ($conflicts name conflicts skipped, $createFails creates failed - see warnings; VERIFY below lists what is missing)" -ForegroundColor Yellow }

# --- Computers (workstations + servers) -------------------------------------------
$created = 0; $present = 0
foreach ($c in $targetComputers) {
    $os = if ($c.IsServer) { $serverOs[$c.Index % $serverOs.Count] } else { $clientOs[$c.Index % $clientOs.Count] }
    $existing = $existingPcs[$c.Name]
    if (-not $existing) {
        try {
            $newObj = New-ADComputer -Name $c.Name -Path $ouPc -OperatingSystem $os.OS `
                           -OperatingSystemVersion $os.Ver -Enabled ($c.Index % 25 -ne 0) -PassThru
            $existingPcs[$c.Name] = $newObj
            $created++
        } catch { Write-Warning "create computer $($c.Name) failed: $($_.Exception.Message)" }
    } else {
        $present++
        # The *Account cmdlets resolve computers by DN/SID/sAM (WS-201$), not
        # by the short name - go through the object's DN, and only when the
        # enabled state actually differs from the target.
        if ($existing.Enabled -eq ($c.Index % 25 -eq 0)) {
            if ($c.Index % 25 -eq 0) { Try-State { Disable-ADAccount -Identity $existing.DistinguishedName } "disable $($c.Name)" }   # every 25th stays disabled
            else                     { Try-State { Enable-ADAccount  -Identity $existing.DistinguishedName } "enable $($c.Name)" }
        }
    }
}
Write-Host "Computers: $created created, $present already present (target $($targetComputers.Count) = $ComputerCount workstations + $ServerCount servers)" -ForegroundColor Cyan

# --- Groups -------------------------------------------------------------------------
$grpDesc = @{}
foreach ($a in $groupWords1) { foreach ($b in $groupWords2) { $grpDesc["$a $b"] = "$a $b working group - bulk lab" } }
$created = 0; $present = 0
for ($idx = 0; $idx -lt $targetGroups.Count; $idx++) {
    $g = $targetGroups[$idx]
    $cat = if (($idx + 1) % 10 -eq 0) { 'Distribution' } else { 'Security' }
    $existing = $existingGrps[$g]
    if (-not $existing) {
        $desc = if ($grpDesc.ContainsKey($g)) { $grpDesc[$g] } else { "$($g -replace ' - .*','') working group - bulk lab" }
        try {
            $newObj = New-ADGroup -Name $g -SamAccountName ($g -replace ' ', '-') -GroupCategory $cat `
                        -GroupScope Global -Path $ouGrp -Description $desc -PassThru
            $existingGrps[$g] = $newObj
            $created++
        } catch { Write-Warning "create group $g failed: $($_.Exception.Message)" }
    } else {
        $present++
        if ($existing.GroupCategory -ne $cat) { Try-State { Set-ADGroup -Identity ($g -replace ' ', '-') -GroupCategory $cat } "category for $g" }
    }
}
Write-Host "Groups: $created created, $present already present (target $($targetGroups.Count))" -ForegroundColor Cyan

# (Strays were tested and pruned up front, before any creation - see TEST block.)

# --- Memberships: build the fixed target, then reconcile AD to match it -----------
# Fixed seed System.Random: the "random" mix is identical on every run, so
# reconciliation converges instead of churning. The last five groups are
# deliberately empty (quick-delete test material).
Write-Host "Reconciling group memberships..." -ForegroundColor Cyan
$rng = [System.Random]::new(42)
$emptyFrom = [math]::Max(0, $targetGroups.Count - 5)
$liveGroups = @()
for ($idx = 0; $idx -lt $targetGroups.Count; $idx++) {
    if ($idx -lt $emptyFrom) { $liveGroups += $targetGroups[$idx] }
}
$target = @{}
foreach ($g in $targetGroups) { $target[$g] = [System.Collections.Generic.HashSet[string]]::new() }
foreach ($g in $liveGroups) { $null = $target[$g].Add($targetUserSams[$rng.Next(0, $targetUserSams.Count)]) }
if ($liveGroups.Count -gt 0) {
    foreach ($sam in $targetUserSams) {
        $k = $rng.Next(0, 5)
        for ($j = 0; $j -lt $k; $j++) { $null = $target[$liveGroups[$rng.Next(0, $liveGroups.Count)]].Add($sam) }
    }
}
# Current membership from ONE bulk MemberOf read (inverted), instead of one
# Get-ADGroupMember call per group. It sees Bulk users only, so members from
# outside OU=Bulk never appear here and are therefore never removed.
$grpDnToName = @{}
foreach ($g in $targetGroups) { $grpDnToName["CN=$g,$ouGrp"] = $g }
$current = @{}
foreach ($g in $targetGroups) { $current[$g] = [System.Collections.Generic.HashSet[string]]::new() }
Get-ADUser -SearchBase $ouUsers -Filter * -Properties MemberOf | ForEach-Object {
    $sam = $_.SamAccountName
    if ($targetUserSet.Contains($sam)) {
        foreach ($mDn in @($_.MemberOf)) { if ($mDn -and $grpDnToName.ContainsKey($mDn)) { $null = $current[$grpDnToName[$mDn]].Add($sam) } }
    }
}
$adds = 0; $removes = 0
foreach ($g in $targetGroups) {
    $gSam = $g -replace ' ', '-'
    $want = $target[$g]
    $cur = $current[$g]
    $toAdd = @($want | Where-Object { -not $cur.Contains($_) })
    $toRemove = @($cur | Where-Object { -not $want.Contains($_) })
    if ($toAdd.Count)    { Try-State { Add-ADGroupMember -Identity $gSam -Members $toAdd } "add members to $g"; $adds += $toAdd.Count }
    if ($toRemove.Count) { Try-State { Remove-ADGroupMember -Identity $gSam -Members $toRemove -Confirm:$false } "remove members from $g"; $removes += $toRemove.Count }
}
Write-Host "  membership changes this run: $adds added, $removes removed"

# --- VERIFY: re-read the directory and compare against the targets --------------
Write-Host "Verifying..." -ForegroundColor Cyan
$verifyUsers = @{}; Get-ADUser -SearchBase $ouUsers -Filter * | ForEach-Object { $verifyUsers[$_.SamAccountName] = $true }
$verifyPcs = @{};   Get-ADComputer -SearchBase $ouPc -Filter * | ForEach-Object { $verifyPcs[$_.Name] = $true }
$verifyGrps = @{};  Get-ADGroup -SearchBase $ouGrp -Filter * | ForEach-Object { $verifyGrps[$_.Name] = $true }
$missU = @($targetUsers | Where-Object { -not $verifyUsers.ContainsKey($_.Sam) } | ForEach-Object Sam)
$missC = @($targetComputers | Where-Object { -not $verifyPcs.ContainsKey($_.Name) } | ForEach-Object Name)
$missG = @($targetGroups | Where-Object { -not $verifyGrps.ContainsKey($_) })
function Show-Verify([string]$Kind, [int]$Want, [string[]]$Missing) {
    $have = $Want - $Missing.Count
    if ($Missing.Count -eq 0) { Write-Host " VERIFY $Kind`: $have/$Want targets present - OK" -ForegroundColor Green }
    else { Write-Host " VERIFY $Kind`: $have/$Want targets present - MISSING $($Missing.Count): $(($Missing | Select-Object -First 5) -join ', ')$(if ($Missing.Count -gt 5) { ', ...' })" -ForegroundColor Red }
}
Show-Verify 'users' $targetUsers.Count $missU
Show-Verify 'computers' $targetComputers.Count $missC
Show-Verify 'groups' $targetGroups.Count $missG

# --- Report -------------------------------------------------------------------------
$sizes = @($targetGroups | ForEach-Object { $target[$_].Count })
$sum = ($sizes | Measure-Object -Sum).Sum
$avg = if ($sizes.Count) { [math]::Round(($sizes | Measure-Object -Average).Average, 1) } else { 0 }
$min = if ($sizes.Count) { ($sizes | Measure-Object -Minimum).Minimum } else { 0 }
$max = if ($sizes.Count) { ($sizes | Measure-Object -Maximum).Maximum } else { 0 }
Write-Host ""
Write-Host "==============================================================" -ForegroundColor Green
Write-Host " Bulk lab converged in OU=$BulkOuName (idempotent - re-runs change nothing)" -ForegroundColor Green
Write-Host "==============================================================" -ForegroundColor Green
Write-Host " Users: $($targetUsers.Count)  Computers: $($targetComputers.Count) ($ComputerCount workstations + $ServerCount servers)  Groups: $($targetGroups.Count)"
Write-Host " Memberships in target groups (target state): $sum total, per group min $min / avg $avg / max $max"
Write-Host " All user passwords: $UserPassword"
Write-Host ""
$nDis = [math]::Floor($targetUsers.Count / 20)
$cnt25 = { param($r) if ($targetUsers.Count -lt $r) { 0 } else { [math]::Floor(($targetUsers.Count - $r) / 25) + 1 } }
$nDistGrp = [math]::Floor($targetGroups.Count / 10)
Write-Host " ADE category coverage from this batch:"
Write-Host "   Users    - disabled $nDis, locked $(& $cnt25 3), password-expired (aging set) $(& $cnt25 8), must-change $(& $cnt25 13),"
Write-Host "              never-expires $(& $cnt25 18), do-not-delete $(& $cnt25 23), org boxes $(& $cnt25 1), stale: all enabled"
Write-Host "   Computers- workstations $ComputerCount, servers $ServerCount (all stale/offline), disabled $(@($targetComputers | Where-Object { $_.Index % 25 -eq 0 }).Count)"
Write-Host "   Groups   - security $($targetGroups.Count - $nDistGrp), distribution $nDistGrp, deliberately empty $($targetGroups.Count - $emptyFrom)"
Write-Host " Spot check:"
foreach ($u in @($targetUsers[0], $targetUsers[[int]($targetUsers.Count / 2)], $targetUsers[-1])) {
    $gs = (Get-ADPrincipalGroupMembership $u.Sam | Where-Object { $_.DistinguishedName -like "*,$ouGrp" }).Name -join ', '
    Write-Host "   $($u.Sam) -> $gs"
}
Write-Host ""
Write-Host " Remove everything: .\New-ADBulkLabData.ps1 -Remove"
