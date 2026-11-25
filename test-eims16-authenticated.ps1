# Authenticated EIMS #16 test harness. Run only against the verified local/dev API.
# Reads test passwords from the Windows DPAPI-protected credential store and uses
# SUPABASE_URL + SUPABASE_ANON_KEY for sign-in. It never loads the service-role key.

param([string]$BaseUrl = "http://localhost:5000")
$ErrorActionPreference = "Stop"
$ExpectedProjectHost = "rtxmjyenehsjtsccnbxs.supabase.co"
$CredentialPath = Join-Path $env:LOCALAPPDATA "ELMUAZ\EIMS16-test-credentials.xml"
$FixturePrefix = "[EIMS16 TEST]"
$Tokens = @{}
$Accounts = @{}
$Failures = 0

function Get-DotEnvValue([string]$Name) {
  $line = Get-Content -LiteralPath ".env" | Where-Object { $_ -match "^\s*$([regex]::Escape($Name))\s*=" } | Select-Object -First 1
  if (-not $line) { return $null }
  $value = ($line -replace "^\s*$([regex]::Escape($Name))\s*=\s*", "").Trim()
  if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) {
    return $value.Substring(1, $value.Length - 2)
  }
  return ($value -replace '\s+#.*$', '').Trim()
}

function Record([string]$Name, [bool]$Passed) {
  if ($Passed) { Write-Output "PASS $Name" }
  else { Write-Output "FAIL $Name"; $script:Failures++ }
}

function Skip([string]$Name, [string]$Reason) { Write-Output "NOT TESTED $Name ($Reason)" }

function Get-Status($ErrorRecord) {
  if ($ErrorRecord.Exception.Response -and $ErrorRecord.Exception.Response.StatusCode) {
    return [int]$ErrorRecord.Exception.Response.StatusCode
  }
  return 0
}

function Get-SafeMessage($ErrorRecord) {
  # Only surface the API's generic message field. Never echo raw response bodies.
  $raw = $ErrorRecord.ErrorDetails.Message
  if ($raw) {
    try {
      $payload = $raw | ConvertFrom-Json -ErrorAction Stop
      if ($payload.message -is [string] -and $payload.message.Length -le 240) { return $payload.message }
    } catch {}
  }
  return "No safe response message available"
}

function Call-Api([string]$Role, [string]$Method, [string]$Path, $Body = $null) {
  $request = @{
    Uri = "$script:BaseUrl$Path"
    Method = $Method
    TimeoutSec = 25
    Headers = @{ Authorization = "Bearer $($script:Tokens[$Role])" }
  }
  if ($null -ne $Body) { $request.ContentType = "application/json"; $request.Body = $Body | ConvertTo-Json -Depth 10 -Compress }
  try {
    $response = Invoke-WebRequest @request
    $data = if ($response.Content) { $response.Content | ConvertFrom-Json } else { $null }
    return [pscustomobject]@{ Status = [int]$response.StatusCode; Data = $data }
  }
  catch {
    $status = Get-Status $_
    Write-Host "HTTP $status $Role $Method $Path — $(Get-SafeMessage $_)"
    return [pscustomobject]@{ Status = $status; Data = $null }
  }
}

function Get-ListData($Result, [string]$Property) {
  if ($Result.Status -ne 200 -or $null -eq $Result.Data) { return @() }
  return @($Result.Data.$Property)
}

function Ensure-TestDepartment($CeoProfile, [string]$Name, [string]$Code) {
  $list = Call-Api "ceo" "GET" "/api/departments"
  if ($list.Status -ne 200) { throw "CEO department list prerequisite failed." }
  $rows = @(Get-ListData $list "departments")
  $matches = @($rows | Where-Object { $_.code -eq $Code -or $_.name -eq $Name })
  if ($matches.Count -gt 1) { throw "Duplicate marked department fixture found." }
  if ($matches.Count -eq 1) {
    if ($matches[0].name -ne $Name -or $matches[0].code -ne $Code) { throw "Department fixture marker collision." }
    return $matches[0]
  }
  $created = Call-Api "ceo" "POST" "/api/departments" @{ name = $Name; code = $Code }
  if ($created.Status -ne 201 -or -not $created.Data.department.id) { throw "Could not create a marked test department." }
  return $created.Data.department
}

function Ensure-TestProject([string]$Name, [string]$DepartmentId, [AllowNull()][string]$LeadId = $null) {
  if ([string]::IsNullOrWhiteSpace($LeadId)) { $LeadId = $null }
  $list = Call-Api "ceo" "GET" "/api/projects"
  if ($list.Status -ne 200) { throw "CEO project list prerequisite failed." }
  $matches = @((Get-ListData $list "projects") | Where-Object { $_.name -eq $Name })
  Write-Host "Fixture check: project '$Name' exact-name matches=$($matches.Count)."
  if ($matches.Count -gt 1) { throw "Duplicate marked project fixture found." }
  if ($matches.Count -eq 1) {
    if ($matches[0].department_id -ne $DepartmentId) {
      Write-Host "Fixture check: $Name exists; expected department does not match. No project was modified."
      throw "Project fixture ownership collision."
    }
    $existingLeadId = if ([string]::IsNullOrWhiteSpace([string]$matches[0].lead_id)) { $null } else { [string]$matches[0].lead_id }
    if ($existingLeadId -ne $LeadId) {
      # Repair only a marked fixture created by an earlier interrupted run, where
      # the expected test lead is set and the existing test project has no lead.
      if ($Name -eq "$FixturePrefix Employee Access Project" -and $LeadId -and -not $existingLeadId) {
        $repaired = Call-Api "ceo" "PATCH" "/api/projects/$($matches[0].id)" @{ lead_id = $LeadId }
        if ($repaired.Status -ne 200 -or $repaired.Data.project.lead_id -ne $LeadId) { throw "Could not repair the marked employee-access project fixture." }
        return $repaired.Data.project
      }
      Write-Host "Fixture check: $Name exists; department matches, but its lead does not match the expected test-fixture state. No project was modified."
      throw "Project fixture ownership collision."
    }
    return $matches[0]
  }
  $projectBody = @{
    name = $Name; department_id = $DepartmentId
    description = "Dedicated EIMS #16 test fixture; do not use for business work."
  }
  if ($LeadId) { $projectBody.lead_id = $LeadId }
  $created = Call-Api "ceo" "POST" "/api/projects" $projectBody
  Write-Host "Fixture check: project '$Name' create status=$($created.Status); returned ID=$([bool]$created.Data.project.id)."
  if ($created.Status -ne 201 -or -not $created.Data.project.id) { throw "Could not create a marked test project." }
  return $created.Data.project
}

function Ensure-TestTask([string]$Title, [string]$ProjectId, [string]$AssigneeId) {
  $list = Call-Api "ceo" "GET" "/api/tasks"
  if ($list.Status -ne 200) { throw "CEO task list prerequisite failed." }
  $matches = @((Get-ListData $list "tasks") | Where-Object { $_.title -eq $Title })
  if ($matches.Count -gt 1) { throw "Duplicate marked task fixture found." }
  if ($matches.Count -eq 1) {
    if ($matches[0].project_id -ne $ProjectId -or $matches[0].assigned_to -ne $AssigneeId) { throw "Task fixture ownership collision." }
    return $matches[0]
  }
  $created = Call-Api "ceo" "POST" "/api/tasks" @{
    title = $Title; description = "Dedicated EIMS #16 test fixture; do not use for business work."
    project_id = $ProjectId; assigned_to = $AssigneeId; priority = "low"; stage = "assigned"
  }
  if ($created.Status -ne 201 -or -not $created.Data.task.id) { throw "Could not create a marked test task." }
  return $created.Data.task
}

try {
  if (-not (Test-Path -LiteralPath ".env") -or -not (Test-Path -LiteralPath $CredentialPath)) {
    throw "Local config or DPAPI credential store is missing."
  }
  $supabaseUrl = (Get-DotEnvValue "SUPABASE_URL").TrimEnd('/')
  $anonKey = Get-DotEnvValue "SUPABASE_ANON_KEY"
  if (-not $supabaseUrl -or -not $anonKey -or ([uri]$supabaseUrl).Host -ne $ExpectedProjectHost) {
    throw "Configured Supabase project is missing or differs from the verified development project."
  }
  $script:BaseUrl = $BaseUrl.TrimEnd('/')

  $records = @(Import-Clixml -LiteralPath $CredentialPath)
  foreach ($role in @("ceo", "department_head", "accountant", "employee")) {
    $entry = @($records | Where-Object Role -eq $role)
    if ($entry.Count -ne 1 -or -not $entry[0].Credential -or -not $entry[0].UserId) { throw "Credential store is incomplete." }
    $Accounts[$role] = $entry[0]
    $plainPassword = $entry[0].Credential.GetNetworkCredential().Password
    try {
      $loginBody = @{ email = $entry[0].Credential.UserName; password = $plainPassword } | ConvertTo-Json -Compress
      $login = Invoke-RestMethod -Uri "$supabaseUrl/auth/v1/token?grant_type=password" -Method Post `
        -Headers @{ apikey = $anonKey } -ContentType "application/json" -Body $loginBody -TimeoutSec 25
      $Tokens[$role] = $login.access_token
      Record "$role test account sign-in" ([bool]$Tokens[$role])
      $login.refresh_token = ""
      $login.access_token = ""
    } catch { Record "$role test account sign-in" $false }
    finally { $plainPassword = $null; $loginBody = $null; $login = $null }
  }
  if (@($Tokens.Keys).Count -ne 4) { throw "Not all test accounts authenticated; remaining checks stopped." }

  $profiles = @{}
  foreach ($role in @("ceo", "department_head", "accountant", "employee")) {
    $me = Call-Api $role "GET" "/api/me"
    $profile = $me.Data.profile
    $expectedId = $Accounts[$role].UserId
    $expectedRole = if ($role -eq "department_head") { "department_head" } else { $role }
    Record "$role /api/me identity and role" ($me.Status -eq 200 -and $profile.id -eq $expectedId -and $profile.role -eq $expectedRole -and $profile.status -eq "active")
    if ($me.Status -eq 200) { $profiles[$role] = $profile }
  }

  $health = $null
  try { $health = Invoke-RestMethod -Uri "$script:BaseUrl/api/health" -TimeoutSec 10 } catch {}
  Record "Local backend health" ([bool]$health.success)
  foreach ($authCase in @(
    @{ Name = "missing bearer"; Header = $null },
    @{ Name = "malformed bearer"; Header = "Bearer" },
    @{ Name = "invalid bearer"; Header = "Bearer invalid-eims16-token" }
  )) {
    $status = 0
    try {
      $headers = if ($authCase.Header) { @{ Authorization = $authCase.Header } } else { @{} }
      Invoke-WebRequest -Uri "$script:BaseUrl/api/me" -Headers $headers -TimeoutSec 25 | Out-Null
      $status = 200
    } catch { $status = Get-Status $_ }
    Record "$($authCase.Name) returns 401" ($status -eq 401)
  }
  Skip "expired signed access token" "no expired Supabase-signed JWT fixture is provisioned; invalid token is tested"

  # Read-only role matrix for all authenticated staff resources.
  foreach ($role in @("ceo", "department_head", "accountant", "employee")) {
    foreach ($resource in @("profiles", "departments", "projects", "tasks", "meetings", "announcements", "notifications")) {
      $result = Call-Api $role "GET" "/api/$resource"
      Record "$role can access GET /api/$resource" ($result.Status -eq 200)
    }
    $pending = Call-Api $role "GET" "/api/profiles/pending"
    Record "$role pending-profile authorization" $(if ($role -eq "ceo") { $pending.Status -eq 200 } else { $pending.Status -eq 403 })
    $audit = Call-Api $role "GET" "/api/audit-logs"
    Record "$role audit-log authorization" $(if ($role -eq "ceo") { $audit.Status -eq 200 } else { $audit.Status -eq 403 })
    foreach ($financePath in @("/api/finance/metrics", "/api/finance/transactions")) {
      $finance = Call-Api $role "GET" $financePath
      $isFinanceRole = $role -in @("ceo", "accountant")
      Record "$role finance authorization $financePath" $(if ($isFinanceRole) { $finance.Status -eq 200 } else { $finance.Status -eq 403 })
    }
  }

  # Test only the dedicated account's profile IDs. Invalid requests must not mutate records.
  foreach ($role in @("ceo", "department_head", "accountant", "employee")) {
    $profileId = $Accounts[$role].UserId
    $protected = Call-Api $role "PATCH" "/api/profiles/$profileId" @{ role = "ceo" }
    Record "$role cannot self-assign a protected role" ($protected.Status -in @(400, 403))
    $unknown = Call-Api $role "PATCH" "/api/profiles/$profileId" @{ auth_provider = "forged" }
    Record "$role cannot submit an unknown/protected profile field" ($unknown.Status -eq 400)
    $after = Call-Api $role "GET" "/api/me"
    Record "$role profile role remained unchanged" ($after.Status -eq 200 -and $after.Data.profile.role -eq $role)
  }
  foreach ($role in @("department_head", "accountant", "employee")) {
    $approval = Call-Api $role "PATCH" "/api/profiles/00000000-0000-4000-8000-000000000001/approve" @{}
    Record "$role cannot approve profiles" ($approval.Status -eq 403)
  }
  $ceoApproval = Call-Api "ceo" "PATCH" "/api/profiles/00000000-0000-4000-8000-000000000001/approve" @{}
  Record "CEO approval route resolves a missing target without changing data" ($ceoApproval.Status -eq 404)

  # CEO and department head must pass authorization before malformed admin payload validation.
  foreach ($role in @("ceo", "department_head", "accountant", "employee")) {
    $projectCreate = Call-Api $role "POST" "/api/projects" @{}
    $expected = if ($role -in @("ceo", "department_head")) { 400 } else { 403 }
    Record "$role project-create authorization boundary" ($projectCreate.Status -eq $expected)
    $taskCreate = Call-Api $role "POST" "/api/tasks" @{}
    $expected = if ($role -in @("ceo", "department_head")) { 400 } else { 403 }
    Record "$role task-create authorization boundary" ($taskCreate.Status -eq $expected)
    $meetingCreate = Call-Api $role "POST" "/api/meetings" @{}
    $expected = if ($role -in @("ceo", "department_head")) { 400 } else { 403 }
    Record "$role meeting-create authorization boundary" ($meetingCreate.Status -eq $expected)
    $announcementCreate = Call-Api $role "POST" "/api/announcements" @{}
    $expected = if ($role -eq "ceo") { 400 } else { 403 }
    Record "$role announcement-create authorization boundary" ($announcementCreate.Status -eq $expected)
    $departmentCreate = Call-Api $role "POST" "/api/departments" @{}
    $expected = if ($role -eq "ceo") { 400 } else { 403 }
    Record "$role department-create authorization boundary" ($departmentCreate.Status -eq $expected)
  }

  # Create/reuse only clearly labeled #16 fixture records via the backend API.
  $script:HarnessStage = "marked test fixture preflight/creation"
  $script:HarnessStage = "isolation department ensure"
  $testDepartment = Ensure-TestDepartment $profiles.ceo "TEST EIMS16 Isolation" "EIMS16X"
  Write-Host "Fixture check: isolation department is present."
  $script:HarnessStage = "test department membership preflight"
  $baseDepartmentId = $profiles.department_head.department_id
  if (-not $baseDepartmentId -or $baseDepartmentId -ne $profiles.employee.department_id) { throw "Test head and employee are not assigned to the same department." }
  $profileList = Call-Api "ceo" "GET" "/api/profiles"
  $deptRows = @(Get-ListData $profileList "profiles")
  $externalMembers = @($deptRows | Where-Object { $_.department_id -eq $testDepartment.id -and $_.id -notin @($Accounts.Values | ForEach-Object { $_.UserId }) })
  if ($externalMembers.Count) { throw "The isolation fixture department contains non-test profiles." }

  Write-Host "Fixture check: department boundaries contain only the expected test membership."
  $script:HarnessStage = "marked project ensure"
  $runPrefix = "$FixturePrefix 2026-10-09B"
  $employeeProject = Ensure-TestProject -Name "$runPrefix Employee Access Project" -DepartmentId $baseDepartmentId -LeadId ([string]$profiles["department_head"].id)
  $restrictedProject = Ensure-TestProject -Name "$runPrefix Restricted Project" -DepartmentId $baseDepartmentId -LeadId $null
  $crossDepartmentProject = Ensure-TestProject -Name "$runPrefix Cross Department Project" -DepartmentId ([string]$testDepartment.id) -LeadId $null
  $employeeTask = Ensure-TestTask "$runPrefix Employee-Owned Task" $employeeProject.id $profiles.employee.id
  $headTask = Ensure-TestTask "$runPrefix Head-Owned Task" $employeeProject.id $profiles.department_head.id

  $employeeProjects = Call-Api "employee" "GET" "/api/projects"
  $employeeProjectIds = @((Get-ListData $employeeProjects "projects") | ForEach-Object { $_.id })
  Record "Employee can access project tied to own task" ($employeeProjects.Status -eq 200 -and $employeeProjectIds -contains $employeeProject.id)
  Record "Employee project list excludes unrelated test project" ($employeeProjects.Status -eq 200 -and $employeeProjectIds -notcontains $restrictedProject.id -and $employeeProjectIds -notcontains $crossDepartmentProject.id)
  $employeeRestricted = Call-Api "employee" "GET" "/api/projects/$($restrictedProject.id)"
  $headCrossDept = Call-Api "department_head" "GET" "/api/projects/$($crossDepartmentProject.id)"
  Record "Employee cannot access unrelated project by ID" ($employeeRestricted.Status -eq 404)
  Record "Department Head cannot access another department project by ID" ($headCrossDept.Status -eq 404)

  $employeeTasks = Call-Api "employee" "GET" "/api/tasks"
  $visibleTaskIds = @((Get-ListData $employeeTasks "tasks") | ForEach-Object { $_.id })
  Record "Employee task list includes own assigned test task" ($employeeTasks.Status -eq 200 -and $visibleTaskIds -contains $employeeTask.id)
  Record "Employee task list excludes head-owned test task" ($employeeTasks.Status -eq 200 -and $visibleTaskIds -notcontains $headTask.id)
  $employeeOwnComments = Call-Api "employee" "GET" "/api/tasks/$($employeeTask.id)/comments"
  $employeeOtherComments = Call-Api "employee" "GET" "/api/tasks/$($headTask.id)/comments"
  $headOwnComments = Call-Api "department_head" "GET" "/api/tasks/$($headTask.id)/comments"
  Record "Employee can read comments on own task" ($employeeOwnComments.Status -eq 200)
  Record "Employee cannot read comments on another user's task" ($employeeOtherComments.Status -eq 404)
  Record "Department Head can read task in assigned department" ($headOwnComments.Status -eq 200)
  $forgedComment = Call-Api "employee" "POST" "/api/tasks/$($employeeTask.id)/comments" @{ comment = "$FixturePrefix author derivation"; author_id = $profiles.ceo.id }
  Record "Comment author cannot be supplied by caller" ($forgedComment.Status -eq 400)

  # A uniquely tagged specific meeting tests participant visibility without editing existing meetings.
  $topic = "$runPrefix Employee-Only Meeting"
  $headMeetings = Call-Api "department_head" "GET" "/api/meetings"
  $meeting = @((Get-ListData $headMeetings "meetings") | Where-Object { $_.topic -eq $topic -and $_.created_by -eq $profiles.department_head.id }) | Select-Object -First 1
  if (-not $meeting) {
    $createdMeeting = Call-Api "department_head" "POST" "/api/meetings" @{
      topic = $topic; type = "specific"; meeting_time = (Get-Date).ToUniversalTime().AddDays(7).ToString("o")
      agenda = "Dedicated EIMS #16 test fixture."; participants = @($profiles.employee.id)
    }
    if ($createdMeeting.Status -eq 201) { $meeting = $createdMeeting.Data.meeting }
  }
  Record "Department Head created/reused a marked participant meeting" ([bool]$meeting.id)
  if ($meeting.id) {
    $employeeMeetings = Call-Api "employee" "GET" "/api/meetings"
    $accountantMeetings = Call-Api "accountant" "GET" "/api/meetings"
    Record "Meeting participant can see specific test meeting" ($employeeMeetings.Status -eq 200 -and @((Get-ListData $employeeMeetings "meetings") | Where-Object id -eq $meeting.id).Count -eq 1)
    Record "Non-participant cannot see specific test meeting" ($accountantMeetings.Status -eq 200 -and @((Get-ListData $accountantMeetings "meetings") | Where-Object id -eq $meeting.id).Count -eq 0)
  }
  $crossDeptInvite = Call-Api "department_head" "POST" "/api/meetings" @{
    topic = "$runPrefix Rejected Cross-Department Meeting"; type = "specific"
    meeting_time = (Get-Date).ToUniversalTime().AddDays(7).ToString("o"); participants = @($profiles.accountant.id)
  }
  Record "Department Head cannot invite out-of-department profile" ($crossDeptInvite.Status -eq 403)

  # Acknowledgment is made only against a uniquely tagged test announcement.
  $announcementTitle = "$runPrefix Acknowledgment Ownership"
  $ceoAnnouncements = Call-Api "ceo" "GET" "/api/announcements"
  $announcement = @((Get-ListData $ceoAnnouncements "announcements") | Where-Object { $_.title -eq $announcementTitle -and $_.created_by -eq $profiles.ceo.id }) | Select-Object -First 1
  if (-not $announcement) {
    $createdAnnouncement = Call-Api "ceo" "POST" "/api/announcements" @{
      title = $announcementTitle; content = "Dedicated EIMS #16 test fixture."; requires_acknowledgment = $true
    }
    if ($createdAnnouncement.Status -eq 201) { $announcement = $createdAnnouncement.Data.announcement }
  }
  Record "CEO created/reused marked test announcement" ([bool]$announcement.id)
  if ($announcement.id) {
    foreach ($role in @("ceo", "department_head", "accountant", "employee")) {
      $ack = Call-Api $role "POST" "/api/announcements/$($announcement.id)/acknowledge" @{}
      Record "$role can acknowledge test announcement as own profile" ($ack.Status -in @(200, 201) -and $ack.Data.acknowledgment.profile_id -eq $profiles[$role].id)
    }
  }

  # Notification ownership is tested only when a notification exists for the CEO test user.
  $ceoNotifications = Call-Api "ceo" "GET" "/api/notifications"
  $ownedNotification = @((Get-ListData $ceoNotifications "notifications") | Select-Object -First 1)
  if ($ownedNotification.Count -and $ownedNotification[0].id) {
    $crossOwner = Call-Api "employee" "PATCH" "/api/notifications/mark-read" @{ notification_ids = @($ownedNotification[0].id) }
    Record "Employee cannot mark another test user's notification read" ($crossOwner.Status -eq 404)
  } else { Skip "Notification cross-owner check" "no CEO test notification exists" }

  # Same-value probes target only each dedicated test profile and use that user's JWT.
  foreach ($role in @("ceo", "department_head", "accountant", "employee")) {
    $profile = $profiles[$role]
    $directStatus = 0; $directRows = @()
    try {
      $direct = Invoke-RestMethod -Uri "$supabaseUrl/rest/v1/profiles?id=eq.$($profile.id)&select=id" -Method Patch `
        -Headers @{ apikey = $anonKey; Authorization = "Bearer $($Tokens[$role])"; Prefer = "return=representation" } `
        -ContentType "application/json" -Body (@{ full_name = $profile.full_name } | ConvertTo-Json -Compress) -TimeoutSec 25
      $directStatus = 200
      $directRows = if ($null -eq $direct) { @() } else { @($direct) }
    } catch { $directStatus = Get-Status $_ }
    Record "$role direct authenticated profile UPDATE is denied by grants/RLS" ($directStatus -in @(401, 403) -or ($directStatus -eq 200 -and $directRows.Count -eq 0))
  }
  Skip "RLS catalog/policy inspection" "the REST API does not expose pg_policies or pg_class RLS flags"

  # Status probes modify only the three dedicated non-CEO test profiles; each is restored.
  foreach ($statusRole in @("department_head", "accountant", "employee")) {
    $statusProfileId = $Accounts[$statusRole].UserId
    try {
      $activeCheck = Call-Api $statusRole "GET" "/api/tasks"
      Record "$statusRole active status grants staff endpoint access" ($activeCheck.Status -eq 200)
      foreach ($status in @("suspended", "terminated", "inactive", "probation", "on_leave")) {
        $setStatus = Call-Api "ceo" "PATCH" "/api/profiles/$statusProfileId" @{ status = $status }
        $staffRequest = Call-Api $statusRole "GET" "/api/tasks"
        $meRequest = Call-Api $statusRole "GET" "/api/me"
        Record "$statusRole status=$status staff access behavior" ($setStatus.Status -eq 200 -and $staffRequest.Status -eq 403 -and $meRequest.Status -eq 200 -and $meRequest.Data.profile.status -eq $status)
      }
    } finally {
      $restore = Call-Api "ceo" "PATCH" "/api/profiles/$statusProfileId" @{ status = "active" }
      $restoredMe = Call-Api $statusRole "GET" "/api/me"
      Record "$statusRole dedicated profile status restored to active" ($restore.Status -eq 200 -and $restoredMe.Status -eq 200 -and $restoredMe.Data.profile.status -eq "active")
    }
  }
  Skip "CEO account status mutation" "CEO self-lockout protection prevents changing the only test CEO's status"
  Skip "pending_approval staff gate" "profile API requires the dedicated pending-onboarding fixture; not created by this setup"

  # The disbursement probe rejects zero before treasury reservation; no balance is changed.
  foreach ($role in @("ceo", "accountant", "department_head", "employee")) {
    $disbursement = Call-Api $role "POST" "/api/finance/disburse" @{
      recipient_id = $profiles.employee.id; amount = "0.00"; payment_type = "salary"
    }
    $expected = if ($role -in @("ceo", "accountant")) { 400 } else { 403 }
    Record "$role disbursement authorization/validation boundary" ($disbursement.Status -eq $expected)
  }

} catch {
  Write-Output "HARNESS STOPPED during ${script:HarnessStage}: prerequisite or fixture operation failed; details withheld."
  $script:Failures++
} finally {
  foreach ($role in @($Tokens.Keys)) { $Tokens[$role] = $null }
  $Tokens.Clear()
  foreach ($account in $Accounts.Values) {
    if ($account.Credential -and $account.Credential.Password) { $account.Credential.Password.Dispose() }
  }
  $anonKey = $null
  [GC]::Collect()
}

if ($Failures) { Write-Output "Authenticated #16 test run finished with $Failures failure(s)."; $global:LASTEXITCODE = 1; return }
Write-Output "Authenticated #16 test run finished. Review every PASS and NOT TESTED line; this is not a completion claim."
$global:LASTEXITCODE = 0
