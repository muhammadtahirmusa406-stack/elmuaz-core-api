# Local-only, idempotent EIMS #16 test identity/department setup.
# Uses the project service-role key only for controlled admin CRUD. Passwords are
# randomly generated and stored as Windows DPAPI-protected PSCredential XML under
# LocalAppData; no credentials are written into this repository.

$ErrorActionPreference = "Stop"
$ExpectedProjectHost = "rtxmjyenehsjtsccnbxs.supabase.co"
$FixtureMarker = "elmuaz-eims16-test-fixture"
$DepartmentName = "TEST Engineering"
$DepartmentCode = "EIMS16TEST"
$TestUsers = @(
  @{ Key = "ceo"; Role = "ceo"; FullName = "TEST EIMS16 CEO"; Email = "eims16-ceo@example.invalid" },
  @{ Key = "department_head"; Role = "department_head"; FullName = "TEST EIMS16 Department Head"; Email = "eims16-department-head@example.invalid" },
  @{ Key = "accountant"; Role = "accountant"; FullName = "TEST EIMS16 Accountant"; Email = "eims16-accountant@example.invalid" },
  @{ Key = "employee"; Role = "employee"; FullName = "TEST EIMS16 Employee"; Email = "eims16-employee@example.invalid" }
)
$CredentialPath = Join-Path $env:LOCALAPPDATA "ELMUAZ\EIMS16-test-credentials.xml"
$CredentialDirectory = Split-Path -Parent $CredentialPath
$CredentialRecords = @()
$Passwords = @{}
$CreatedOrReused = @{}

function Get-DotEnvValue([string]$Name) {
  $line = Get-Content -LiteralPath ".env" | Where-Object { $_ -match "^\s*$([regex]::Escape($Name))\s*=" } | Select-Object -First 1
  if (-not $line) { return $null }
  $value = ($line -replace "^\s*$([regex]::Escape($Name))\s*=\s*", "").Trim()
  if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) {
    return $value.Substring(1, $value.Length - 2)
  }
  return ($value -replace '\s+#.*$', '').Trim()
}

function Invoke-Supabase([string]$Method, [string]$Path, $Body = $null) {
  $request = @{
    Uri = "$script:ProjectUrl$Path"
    Method = $Method
    Headers = $script:Headers
    TimeoutSec = 30
  }
  if ($null -ne $Body) {
    $request.ContentType = "application/json"
    $request.Body = $Body | ConvertTo-Json -Depth 12 -Compress
  }
  try { return Invoke-RestMethod @request }
  catch {
    $status = 0
    if ($_.Exception.Response -and $_.Exception.Response.StatusCode) { $status = [int]$_.Exception.Response.StatusCode }
    throw "Supabase request failed (HTTP $status); response details withheld."
  }
}

function Get-AuthUsers {
  $users = [System.Collections.Generic.List[object]]::new()
  for ($page = 1; ; $page++) {
    $result = Invoke-Supabase "GET" "/auth/v1/admin/users?page=$page&per_page=1000"
    foreach ($user in @($result.users)) { if ($user) { $users.Add($user) } }
    if (@($result.users).Count -lt 1000) { break }
  }
  return $users.ToArray()
}

function Get-ProfileByEmail([string]$Email) {
  $filter = [uri]::EscapeDataString("eq.$Email")
  return Get-RestRows "/rest/v1/profiles?select=id,email,full_name,role,status,department_id&email=$filter"
}

function Get-ProfileById([string]$Id) {
  return Get-RestRows "/rest/v1/profiles?select=id,email,full_name,role,status,department_id&id=eq.$Id"
}

function Get-RestRows([string]$Path) {
  $result = Invoke-Supabase "GET" $Path
  if ($null -eq $result) { return }
  foreach ($row in @($result)) { if ($null -ne $row) { Write-Output -NoEnumerate $row } }
}

function Save-CredentialStore {
  if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw "Credential storage requires Windows DPAPI." }
  $CredentialRecords | Export-Clixml -LiteralPath $CredentialPath -Depth 5 -Force
}

function New-RandomPassword {
  $bytes = [byte[]]::new(48)
  [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
  return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

try {
  if (-not (Test-Path -LiteralPath ".env")) { throw "Run setup from the project root containing .env." }
  $supabaseUrl = Get-DotEnvValue "SUPABASE_URL"
  $serviceKey = Get-DotEnvValue "SUPABASE_SERVICE_ROLE_KEY"
  if (-not $supabaseUrl -or -not $serviceKey) { throw "Supabase URL/service-role configuration is missing." }
  $script:ProjectUrl = $supabaseUrl.TrimEnd('/')
  if (([uri]$script:ProjectUrl).Host -ne $ExpectedProjectHost) { throw "Configured project does not match the verified development project; no writes performed." }
  $script:Headers = @{ apikey = $serviceKey; Authorization = "Bearer $serviceKey"; Prefer = "return=representation" }
  $serviceKey = $null
  if (Test-Path -LiteralPath $CredentialPath) {
    try { $CredentialRecords = @(Import-Clixml -LiteralPath $CredentialPath) }
    catch { throw "The local DPAPI credential store could not be read; no account changes performed." }
  }

  # Preflight all deterministic identities and department markers before writes.
  $authUsers = @(Get-AuthUsers)
  $expectedEmails = @($TestUsers | ForEach-Object { $_.Email })
  $unexpectedMarkedUsers = @()
  foreach ($existingAuthUser in $authUsers) {
    if ($existingAuthUser.user_metadata.eims_fixture -ne $FixtureMarker) { continue }
    $isExpectedEmail = $false
    foreach ($expectedEmail in $expectedEmails) {
      if ([string]::Equals([string]$existingAuthUser.email, [string]$expectedEmail, [StringComparison]::OrdinalIgnoreCase)) {
        $isExpectedEmail = $true
        break
      }
    }
    if (-not $isExpectedEmail) { $unexpectedMarkedUsers += $existingAuthUser }
  }
  if ($unexpectedMarkedUsers.Count) { throw "Unexpected accounts already carry the EIMS16 test marker; manual review required." }

  $matchedUsers = @{}
  foreach ($spec in $TestUsers) {
    $authMatches = @($authUsers | Where-Object { $_.email -ieq $spec.Email })
    if ($authMatches.Count -gt 1) { throw "Duplicate Auth identity found for a deterministic test email; no writes performed." }
    if ($authMatches.Count -eq 1 -and $authMatches[0].user_metadata.eims_fixture -ne $FixtureMarker) {
      throw "A deterministic test email belongs to an unmarked Auth user; no writes performed." 
    }
    $matchedUsers[$spec.Key] = if ($authMatches.Count -eq 1) { $authMatches[0] } else { $null }

    $profilesByEmail = @(Get-ProfileByEmail $spec.Email)
    if ($profilesByEmail.Count -gt 1) { throw "Duplicate profile email found for a test identity; no writes performed." }
    if ($profilesByEmail.Count -eq 1 -and $authMatches.Count -eq 1 -and $profilesByEmail[0].id -ne $authMatches[0].id) {
      throw "Test email profile ID does not match its Auth user; no writes performed." 
    }
    if ($profilesByEmail.Count -eq 1 -and $authMatches.Count -eq 0) {
      throw "An orphan profile uses a deterministic test email; no writes performed." 
    }
    $nameFilter = [uri]::EscapeDataString("eq.$($spec.FullName)")
    $profilesByName = @(Get-RestRows "/rest/v1/profiles?select=id,email,full_name&full_name=$nameFilter")
    if (@($profilesByName | Where-Object { $authMatches.Count -eq 0 -or $_.id -ne $authMatches[0].id }).Count) {
      throw "A test profile name is already used by a different profile; no writes performed."
    }
  }

  $departmentsByName = @(Get-RestRows "/rest/v1/departments?select=id,name,code,head_id&name=$([uri]::EscapeDataString("eq.$DepartmentName"))")
  $departmentsByCode = @(Get-RestRows "/rest/v1/departments?select=id,name,code,head_id&code=eq.$DepartmentCode")
  if ($departmentsByName.Count -gt 1 -or $departmentsByCode.Count -gt 1) { throw "Duplicate test department markers found; no writes performed." }
  if ($departmentsByName.Count -eq 1 -and ($departmentsByName[0].code -ne $DepartmentCode)) { throw "TEST Engineering exists without the EIMS16 marker code; no writes performed." }
  if ($departmentsByCode.Count -eq 1 -and ($departmentsByCode[0].name -ne $DepartmentName)) { throw "EIMS16 marker code belongs to another department; no writes performed." }
  if ($departmentsByName.Count -eq 1 -and $departmentsByCode.Count -eq 1 -and $departmentsByName[0].id -ne $departmentsByCode[0].id) {
    throw "Department name/code resolve to different records; no writes performed."
  }

  if ($departmentsByCode.Count -eq 1) {
    $existingDepartmentId = $departmentsByCode[0].id
    $memberRows = @(Get-RestRows "/rest/v1/profiles?select=id,email,department_id&department_id=eq.$existingDepartmentId")
    $allowedIds = @($matchedUsers.Values | Where-Object { $_ } | ForEach-Object { $_.id })
    if (@($memberRows | Where-Object { $_.id -notin $allowedIds }).Count) {
      throw "The marked test department has profiles outside the four dedicated accounts; no writes performed."
    }
    $headId = $departmentsByCode[0].head_id
    if ($headId -and $headId -notin $allowedIds) { throw "The marked test department points to a non-test profile; no writes performed." }
  }

  foreach ($spec in $TestUsers) {
    $user = $matchedUsers[$spec.Key]
    $storedCredential = @($CredentialRecords | Where-Object { $_.Role -eq $spec.Key -and $_.UserId -eq $user.id }) | Select-Object -First 1
    if ($user -and $storedCredential -and $storedCredential.Credential -and $storedCredential.Credential.Password) {
      $CreatedOrReused[$spec.Key] = "reused"
      continue
    }

    $CredentialRecords = @($CredentialRecords | Where-Object { $_.Role -ne $spec.Key })
    $password = New-RandomPassword
    $Passwords[$spec.Key] = $password
    $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
    $credential = [PSCredential]::new($spec.Email, $securePassword)
    $CredentialRecords += [pscustomobject]@{ Role = $spec.Key; UserId = $null; Credential = $credential }

    if (-not (Test-Path -LiteralPath $CredentialDirectory)) { New-Item -ItemType Directory -Path $CredentialDirectory -Force | Out-Null }
    Save-CredentialStore

    $metadata = @{ eims_fixture = $FixtureMarker; eims_fixture_role = $spec.Key }
    if ($user) {
      $authUser = Invoke-Supabase "PUT" "/auth/v1/admin/users/$($user.id)" @{
        password = $password; email_confirm = $true; user_metadata = $metadata
      }
      $userId = $authUser.id
      $CreatedOrReused[$spec.Key] = "reused"
    } else {
      $authUser = Invoke-Supabase "POST" "/auth/v1/admin/users" @{
        email = $spec.Email; password = $password; email_confirm = $true; user_metadata = $metadata
      }
      $userId = $authUser.id
      $CreatedOrReused[$spec.Key] = "created"
    }
    if (-not $userId) { throw "Supabase did not return an Auth UUID for a test account." }
    $matchedUsers[$spec.Key] = [pscustomobject]@{ id = $userId; email = $spec.Email; user_metadata = $metadata }
    ($CredentialRecords | Where-Object Role -eq $spec.Key | Select-Object -First 1).UserId = $userId
    Save-CredentialStore
    $password = $null
    $Passwords[$spec.Key] = $null
    $securePassword = $null
  }

  $department = if ($departmentsByCode.Count -eq 1) { $departmentsByCode[0] } else {
    $created = @(Invoke-Supabase "POST" "/rest/v1/departments" @{ name = $DepartmentName; code = $DepartmentCode; head_id = $null })
    if ($created.Count -ne 1) { throw "Department creation did not return exactly one row." }
    $created[0]
  }
  $departmentId = $department.id
  if (-not $departmentId) { throw "The test department has no UUID." }

  foreach ($spec in $TestUsers) {
    $user = $matchedUsers[$spec.Key]
    $userDepartmentId = if ($spec.Key -in @("department_head", "employee")) { $departmentId } else { $null }
    $profileBody = @{
      id = $user.id; email = $spec.Email; full_name = $spec.FullName
      role = $spec.Role; status = "active"; department_id = $userDepartmentId
    }
    $existingProfile = @(Get-ProfileById $user.id)
    if ($existingProfile.Count -gt 1) { throw "Duplicate profile IDs found for a test identity." }
    if ($existingProfile.Count -eq 1) {
      $null = Invoke-Supabase "PATCH" "/rest/v1/profiles?id=eq.$($user.id)" $profileBody
    } else {
      $null = Invoke-Supabase "POST" "/rest/v1/profiles" $profileBody
    }
  }

  $null = Invoke-Supabase "PATCH" "/rest/v1/departments?id=eq.$departmentId" @{ head_id = $matchedUsers.department_head.id }

  # Re-read each Auth identity/profile and the department relationships.
  $verifiedUsers = @(Get-AuthUsers)
  $verifiedProfiles = @{}
  foreach ($spec in $TestUsers) {
    $authMatch = @($verifiedUsers | Where-Object { $_.id -eq $matchedUsers[$spec.Key].id -and $_.email -ieq $spec.Email })
    if ($authMatch.Count -ne 1 -or $authMatch[0].user_metadata.eims_fixture -ne $FixtureMarker) { throw "Auth identity verification failed for a test account." }
    $profileMatch = @(Get-ProfileById $matchedUsers[$spec.Key].id)
    if ($profileMatch.Count -ne 1 -or $profileMatch[0].role -ne $spec.Role -or $profileMatch[0].status -ne "active") {
      throw "Profile verification failed for a test account."
    }
    $expectedDepartment = if ($spec.Key -in @("department_head", "employee")) { $departmentId } else { $null }
    if ($profileMatch[0].department_id -ne $expectedDepartment) { throw "Department assignment verification failed for a test account." }
    $verifiedProfiles[$spec.Key] = $profileMatch[0]
  }
  $verifiedDepartment = @(Get-RestRows "/rest/v1/departments?select=id,name,code,head_id&id=eq.$departmentId")
  if ($verifiedDepartment.Count -ne 1 -or $verifiedDepartment[0].name -ne $DepartmentName -or
      $verifiedDepartment[0].code -ne $DepartmentCode -or $verifiedDepartment[0].head_id -ne $matchedUsers.department_head.id) {
    throw "Department/head verification failed."
  }
  $departmentMembers = @(Get-RestRows "/rest/v1/profiles?select=id,department_id&department_id=eq.$departmentId")
  $expectedMemberIds = @($matchedUsers.department_head.id, $matchedUsers.employee.id)
  if ($departmentMembers.Count -ne 2 -or @($departmentMembers | Where-Object { $_.id -notin $expectedMemberIds }).Count -gt 0) {
    throw "Department membership verification failed or unexpected profiles are assigned."
  }

  foreach ($record in $CredentialRecords) { Write-Output ("{0}: {1} UUID {2}" -f $record.Role, $CreatedOrReused[$record.Role], $record.UserId) }
  Write-Output "TEST Engineering department UUID $departmentId"
  Write-Output "Credential store: Windows DPAPI-protected local file at $CredentialPath"
  Write-Output "Verification PASS: Auth/profile UUIDs, roles, active statuses, department assignments and head pointer match; no duplicate fixture rows detected."
} catch {
  $safeMessage = $_.Exception.Message
  $redactValues = @($serviceKey) + @($Passwords.Values) + @($TestUsers | ForEach-Object { $_.Email })
  foreach ($secretValue in $redactValues) {
    if ($secretValue) { $safeMessage = $safeMessage.Replace([string]$secretValue, "[REDACTED]") }
  }
  $safeMessage = $safeMessage -replace 'Bearer\s+[^\s,;]+', 'Bearer [REDACTED]' `
    -replace 'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+', '[REDACTED TOKEN]'
  if ($safeMessage.Length -gt 250) { $safeMessage = $safeMessage.Substring(0, 250) }
  Write-Error "EIMS16 setup stopped: $safeMessage"
  exit 1
} finally {
  foreach ($key in @($Passwords.Keys)) { $Passwords[$key] = $null }
  $Passwords.Clear()
  foreach ($record in $CredentialRecords) {
    if ($record.Credential -and $record.Credential.Password) { $record.Credential.Password.Dispose() }
  }
  $serviceKey = $null
  $script:Headers = $null
  $securePassword = $null
  [GC]::Collect()
}
