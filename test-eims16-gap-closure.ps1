# Local-only execution of remaining EIMS #16 high-value checks.
# Passwords are read only from the Windows DPAPI credential store. No credential,
# JWT, or service-role value is printed or written to a file.
param([string]$BaseUrl = "http://localhost:5000")
$ErrorActionPreference = "Stop"
$ExpectedProjectHost = "rtxmjyenehsjtsccnbxs.supabase.co"
$CredentialPath = Join-Path $env:LOCALAPPDATA "ELMUAZ\EIMS16-test-credentials.xml"
$Tokens = @{}
$Accounts = @{}
$Failures = 0
$EmployeePending = $false
$EmployeeRoleChanged = $false
$HeadAssigned = $false
$AdminDepartmentId = $null
$AdminDepartmentCreated = $false
$NotificationId = $null
$NotificationCreated = $false
$ProjectIdUnderTest = $null
$OriginalProjectDepartmentId = $null
$ProjectDepartmentChanged = $false
$BaseUrl = $BaseUrl.TrimEnd('/')

function Get-DotEnvValue([string]$Name) {
  $line = Get-Content -LiteralPath ".env" | Where-Object { $_ -match "^\s*$([regex]::Escape($Name))\s*=" } | Select-Object -First 1
  if (-not $line) { return $null }
  $value = ($line -replace "^\s*$([regex]::Escape($Name))\s*=\s*", "").Trim()
  if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) {
    return $value.Substring(1, $value.Length - 2)
  }
  return ($value -replace '\s+#.*$', '').Trim()
}

function Get-Status($ErrorRecord) {
  if ($ErrorRecord.Exception.Response -and $ErrorRecord.Exception.Response.StatusCode) {
    return [int]$ErrorRecord.Exception.Response.StatusCode
  }
  return 0
}

function Get-SafeMessage($ErrorRecord) {
  $raw = $ErrorRecord.ErrorDetails.Message
  if ($raw) {
    try {
      $payload = $raw | ConvertFrom-Json -ErrorAction Stop
      if ($payload.message -is [string] -and $payload.message.Length -le 240) { return $payload.message }
    } catch {}
  }
  return "No safe response message available"
}

function Record([string]$Name, [bool]$Passed, [string]$Detail = "") {
  if ($Passed) { Write-Output "PASS $Name" }
  else { Write-Output "FAIL $Name"; $script:Failures++ }
  if ($Detail) { Write-Output "  $Detail" }
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
  } catch {
    $status = Get-Status $_
    Write-Host "HTTP $status $Role $Method $Path — $(Get-SafeMessage $_)"
    return [pscustomobject]@{ Status = $status; Data = $null }
  }
}

function Get-ApiRows($Result, [string]$Property) {
  if ($Result.Status -ne 200 -or $null -eq $Result.Data) { return @() }
  return @($Result.Data.$Property)
}

function Call-ServiceRest([string]$Method, [string]$Path, $Body = $null) {
  $request = @{
    Uri = "$script:SupabaseUrl/rest/v1/$Path"
    Method = $Method
    TimeoutSec = 25
    Headers = @{ apikey = $script:ServiceRoleKey; Authorization = "Bearer $script:ServiceRoleKey"; Prefer = "return=representation" }
  }
  if ($null -ne $Body) { $request.ContentType = "application/json"; $request.Body = $Body | ConvertTo-Json -Depth 10 -Compress }
  try {
    $response = Invoke-WebRequest @request
    $data = if ($response.Content) { $response.Content | ConvertFrom-Json } else { $null }
    return [pscustomobject]@{ Status = [int]$response.StatusCode; Data = $data }
  } catch {
    return [pscustomobject]@{ Status = (Get-Status $_); Data = $null }
  }
}

try {
  if (-not (Test-Path -LiteralPath ".env") -or -not (Test-Path -LiteralPath $CredentialPath)) { throw "Local config or DPAPI credential store is missing." }
  $script:SupabaseUrl = (Get-DotEnvValue "SUPABASE_URL").TrimEnd('/')
  $anonKey = Get-DotEnvValue "SUPABASE_ANON_KEY"
  $script:ServiceRoleKey = Get-DotEnvValue "SUPABASE_SERVICE_ROLE_KEY"
  if (-not $script:SupabaseUrl -or -not $anonKey -or -not $script:ServiceRoleKey -or ([uri]$script:SupabaseUrl).Host -ne $ExpectedProjectHost) {
    throw "Configured project or local keys are missing or do not match the verified development project."
  }

  $records = @(Import-Clixml -LiteralPath $CredentialPath)
  foreach ($role in @("ceo", "department_head", "accountant", "employee")) {
    $entry = @($records | Where-Object Role -eq $role)
    if ($entry.Count -ne 1 -or -not $entry[0].Credential -or -not $entry[0].UserId) { throw "Credential store is incomplete." }
    $Accounts[$role] = $entry[0]
    $plainPassword = $entry[0].Credential.GetNetworkCredential().Password
    try {
      $body = @{ email = $entry[0].Credential.UserName; password = $plainPassword } | ConvertTo-Json -Compress
      $login = Invoke-RestMethod -Uri "$script:SupabaseUrl/auth/v1/token?grant_type=password" -Method Post `
        -Headers @{ apikey = $anonKey } -ContentType "application/json" -Body $body -TimeoutSec 25
      $Tokens[$role] = $login.access_token
      Record "$role sign-in for gap tests" ([bool]$Tokens[$role])
      $login.access_token = ""; $login.refresh_token = ""; $login = $null
    } catch { Record "$role sign-in for gap tests" $false }
    finally { $plainPassword = $null; $body = $null }
  }
  if ($Tokens.Count -ne 4) { throw "Not all test accounts authenticated." }

  $me = @{}
  foreach ($role in @("ceo", "department_head", "accountant", "employee")) {
    $result = Call-Api $role "GET" "/api/me"
    if ($result.Status -ne 200 -or $result.Data.profile.id -ne $Accounts[$role].UserId) { throw "Test account profile identity check failed." }
    $me[$role] = $result.Data.profile
  }
  $employeeId = $Accounts.employee.UserId
  $baseDepartmentId = $me.employee.department_id
  if ($me.employee.role -ne "employee" -or $me.employee.status -ne "active" -or -not $baseDepartmentId) { throw "Dedicated employee fixture is not in the expected active department state." }

  # Expiry cannot be safely simulated without the project's JWT signing secret or
  # a Supabase facility that issues already-expired signed tokens.
  Write-Output "BLOCKED expired JWT: no safe signer/expired-token issuer is configured; no forged token was treated as an expiry test."

  # Pending fixture state is changed only on the dedicated Employee profile by
  # the local service-role setup request. The CEO approval route restores active.
  $pendingBody = @{ status = "pending_approval" }
  $pendingSet = Call-ServiceRest "PATCH" "profiles?id=eq.$employeeId&select=id,status,role,department_id" $pendingBody
  $pendingRows = @($pendingSet.Data)
  if ($pendingSet.Status -notin @(200, 204) -or $pendingRows.Count -ne 1 -or $pendingRows[0].id -ne $employeeId) {
    throw "Could not set the dedicated Employee test profile to pending_approval."
  }
  $EmployeePending = $true
  $pendingMe = Call-Api "employee" "GET" "/api/me"
  $pendingTasks = Call-Api "employee" "GET" "/api/tasks"
  Record "pending profile remains identifiable at /api/me" ($pendingMe.Status -eq 200 -and $pendingMe.Data.profile.status -eq "pending_approval")
  Record "pending profile is rejected by protected staff endpoint" ($pendingTasks.Status -eq 403) "GET /api/tasks"
  foreach ($role in @("department_head", "accountant", "employee")) {
    $attempt = Call-Api $role "PATCH" "/api/profiles/$employeeId/approve" @{}
    Record "$role cannot approve the real pending test profile" ($attempt.Status -eq 403)
  }
  $approved = Call-Api "ceo" "PATCH" "/api/profiles/$employeeId/approve" @{}
  if ($approved.Status -eq 200 -and $approved.Data.profile.status -eq "active") { $EmployeePending = $false }
  $approvalAudit = Call-ServiceRest "GET" "profiles?select=id,status,approved_by,approved_at&id=eq.$employeeId"
  $approvalRows = @($approvalAudit.Data)
  Record "CEO approves the pending test profile and restores active" ($approved.Status -eq 200 -and $approved.Data.profile.status -eq "active" -and $approvalAudit.Status -eq 200 -and $approvalRows.Count -eq 1 -and $approvalRows[0].approved_by -eq $Accounts.ceo.UserId -and $approvalRows[0].approved_at)

  # Accountant project/task IDOR: test fixture project is led by the test head;
  # its test tasks are assigned to Employee and Department Head, not Accountant.
  $projectList = Call-Api "ceo" "GET" "/api/projects"
  $project = @((Get-ApiRows $projectList "projects") | Where-Object { $_.name -eq "[EIMS16 TEST] 2026-10-09B Employee Access Project" }) | Select-Object -First 1
  $taskList = Call-Api "ceo" "GET" "/api/tasks"
  $task = @((Get-ApiRows $taskList "tasks") | Where-Object { $_.title -eq "[EIMS16 TEST] 2026-10-09B Employee-Owned Task" }) | Select-Object -First 1
  if (-not $project.id -or -not $task.id -or $task.assigned_to -eq $Accounts.accountant.UserId -or $task.assigned_by -eq $Accounts.accountant.UserId) {
    throw "Marked project/task IDOR fixtures are missing or not isolated from the Accountant."
  }
  $ceoProject = Call-Api "ceo" "GET" "/api/projects/$($project.id)"
  $accountantProject = Call-Api "accountant" "GET" "/api/projects/$($project.id)"
  $ceoTaskComments = Call-Api "ceo" "GET" "/api/tasks/$($task.id)/comments"
  $accountantTaskComments = Call-Api "accountant" "GET" "/api/tasks/$($task.id)/comments"
  Record "CEO can access the task by ID through its comment resource" ($ceoProject.Status -eq 200 -and $ceoTaskComments.Status -eq 200)
  Record "Accountant cannot read unrelated project by ID" ($accountantProject.Status -eq 404)
  Record "Accountant cannot access comments for unassigned task by ID" ($accountantTaskComments.Status -eq 404)
  Write-Output "BLOCKED direct task-detail IDOR: no GET /api/tasks/:id route exists; the nested comment resource was tested instead."

  # Notification fixture only: create/reuse one exact marker on the Employee's
  # profile using service-role access. Service role is not used as RLS evidence.
  $notificationTitle = "[EIMS16 TEST] ownership 2026-10-09"
  $ownedRows = Call-ServiceRest "GET" "notifications?select=id,profile_id,title,message,type,is_read&profile_id=eq.$employeeId"
  if ($ownedRows.Status -ne 200) { throw "Could not inspect notifications for the dedicated Employee fixture." }
  $matches = @($ownedRows.Data | Where-Object { $_.title -eq $notificationTitle })
  if ($matches.Count -gt 1) { throw "Duplicate exact test notification fixtures exist." }
  if ($matches.Count -eq 1) {
    if ($matches[0].profile_id -ne $employeeId -or $matches[0].message -ne "Dedicated EIMS #16 notification ownership fixture.") { throw "Notification fixture marker collision." }
    $notification = $matches[0]
  } else {
    $created = Call-ServiceRest "POST" "notifications" @{
      profile_id = $employeeId; title = $notificationTitle
      message = "Dedicated EIMS #16 notification ownership fixture."; type = "general"; is_read = $false
    }
    if ($created.Status -ne 201 -or @($created.Data).Count -ne 1) { throw "Could not create the marked notification fixture." }
    $notification = $created.Data[0]
    $NotificationCreated = $true
  }
  $NotificationId = $notification.id
  $employeeNotifications = Call-Api "employee" "GET" "/api/notifications"
  $accountantNotifications = Call-Api "accountant" "GET" "/api/notifications"
  $employeeHas = @((Get-ApiRows $employeeNotifications "notifications") | Where-Object id -eq $NotificationId).Count -eq 1
  $accountantHas = @((Get-ApiRows $accountantNotifications "notifications") | Where-Object id -eq $NotificationId).Count -eq 1
  Record "notification owner can read the marked notification" ($employeeNotifications.Status -eq 200 -and $employeeHas)
  Record "another role cannot read the owner's notification" ($accountantNotifications.Status -eq 200 -and -not $accountantHas)
  $crossMark = Call-Api "accountant" "PATCH" "/api/notifications/mark-read" @{ notification_ids = @($NotificationId) }
  Record "another role cannot modify the owner's notification" ($crossMark.Status -eq 404)
  $ownMark = Call-Api "employee" "PATCH" "/api/notifications/mark-read" @{ notification_ids = @($NotificationId) }
  $afterMark = Call-Api "employee" "GET" "/api/notifications"
  $marked = @((Get-ApiRows $afterMark "notifications") | Where-Object id -eq $NotificationId | Where-Object is_read).Count -eq 1
  Record "owner can mark the test notification read" ($ownMark.Status -eq 200 -and $marked)

  # CEO-only profile administration: temporarily change the dedicated Employee
  # role, verify it, then restore the original role.
  foreach ($role in @("department_head", "accountant", "employee")) {
    $selfId = $Accounts[$role].UserId
    $requestedRole = if ($role -eq "employee") { "accountant" } else { "employee" }
    $denied = Call-Api $role "PATCH" "/api/profiles/$selfId" @{ role = $requestedRole }
    Record "$role cannot administer its own role" ($denied.Status -eq 403)
  }
  $roleChange = Call-Api "ceo" "PATCH" "/api/profiles/$employeeId" @{ role = "accountant" }
  if ($roleChange.Status -eq 200) { $EmployeeRoleChanged = $true }
  $roleVerify = Call-Api "employee" "GET" "/api/me"
  Record "CEO can administer the dedicated Employee role" ($roleChange.Status -eq 200 -and $roleVerify.Status -eq 200 -and $roleVerify.Data.profile.role -eq "accountant")
  $restoreRole = Call-Api "ceo" "PATCH" "/api/profiles/$employeeId" @{ role = "employee" }
  if ($restoreRole.Status -eq 200) { $EmployeeRoleChanged = $false }
  Record "CEO restores the dedicated Employee role" ($restoreRole.Status -eq 200)

  # CEO department management uses a new exact test department. The Employee
  # test profile is assigned as head only temporarily, then restored.
  $departmentName = "TEST EIMS16 Admin Mutation 2026-10-09"
  $departmentCode = "E16ADMIN1009"
  $departments = Call-Api "ceo" "GET" "/api/departments"
  $matches = @((Get-ApiRows $departments "departments") | Where-Object { $_.name -eq $departmentName -or $_.code -eq $departmentCode })
  if ($matches.Count -gt 1) { throw "Duplicate exact department test fixtures exist." }
  if ($matches.Count -eq 1) {
    if ($matches[0].name -notin @($departmentName, "$departmentName Verified") -or $matches[0].code -ne $departmentCode) { throw "Department fixture marker collision." }
    $adminDepartment = $matches[0]
  } else {
    $createdDepartment = Call-Api "ceo" "POST" "/api/departments" @{ name = $departmentName; code = $departmentCode }
    if ($createdDepartment.Status -ne 201 -or -not $createdDepartment.Data.department.id) { throw "Could not create the marked department fixture." }
    $adminDepartment = $createdDepartment.Data.department
    $AdminDepartmentCreated = $true
  }
  $AdminDepartmentId = $adminDepartment.id
  if ($adminDepartment.head_id -and $adminDepartment.head_id -ne $employeeId) { throw "Department fixture already has a different head; refusing to change it." }
  $departmentUpdate = Call-Api "ceo" "PATCH" "/api/departments/$AdminDepartmentId" @{ name = "$departmentName Verified" }
  Record "CEO can update a marked department" ($departmentUpdate.Status -eq 200 -and $departmentUpdate.Data.department.name -eq "$departmentName Verified")
  foreach ($role in @("department_head", "accountant", "employee")) {
    $denied = Call-Api $role "PATCH" "/api/departments/$AdminDepartmentId" @{ name = "$departmentName Denied" }
    Record "$role cannot perform CEO-only department update" ($denied.Status -eq 403)
    $headDenied = Call-Api $role "PATCH" "/api/departments/$AdminDepartmentId/head" @{ head_id = $employeeId }
    Record "$role cannot assign a department head" ($headDenied.Status -eq 403)
  }
  $headAssignment = Call-Api "ceo" "PATCH" "/api/departments/$AdminDepartmentId/head" @{ head_id = $employeeId }
  if ($headAssignment.Status -eq 200) { $HeadAssigned = $true }
  $headProfile = Call-Api "employee" "GET" "/api/me"
  Record "CEO can assign the dedicated test profile as department head" ($headAssignment.Status -eq 200 -and $headProfile.Status -eq 200 -and $headProfile.Data.profile.role -eq "department_head" -and $headProfile.Data.profile.department_id -eq $AdminDepartmentId)
  $headClear = Call-Api "ceo" "PATCH" "/api/departments/$AdminDepartmentId/head" @{ head_id = $null }
  $employeeRoleRestore = Call-Api "ceo" "PATCH" "/api/profiles/$employeeId" @{ role = "employee" }
  $employeeDepartmentRestore = Call-Api "ceo" "PATCH" "/api/profiles/$employeeId" @{ department_id = $baseDepartmentId }
  $employeeMeRestored = Call-Api "employee" "GET" "/api/me"
  if ($headClear.Status -eq 200 -and $employeeRoleRestore.Status -eq 200 -and $employeeDepartmentRestore.Status -eq 200) { $HeadAssigned = $false }
  Record "Department-head test assignment is cleared and Employee profile restored" ($headClear.Status -eq 200 -and $employeeRoleRestore.Status -eq 200 -and $employeeDepartmentRestore.Status -eq 200 -and $employeeMeRestored.Data.profile.role -eq "employee" -and $employeeMeRestored.Data.profile.department_id -eq $baseDepartmentId)

  # CEO project department reassignment is tested on the marked cross-department
  # project and reverted in finally. Employee and Accountant are role-denied;
  # Department Head is expected to receive 404 for a project outside its scope.
  $crossProjectName = "[EIMS16 TEST] 2026-10-09B Cross Department Project"
  $project = @((Get-ApiRows $projectList "projects") | Where-Object name -eq $crossProjectName) | Select-Object -First 1
  if (-not $project.id -or $project.department_id -eq $baseDepartmentId -or $project.lead_id) { throw "Marked cross-department project is not safely isolated." }
  $ProjectIdUnderTest = $project.id
  $OriginalProjectDepartmentId = $project.department_id
  $projectMove = Call-Api "ceo" "PATCH" "/api/projects/$($project.id)" @{ department_id = $baseDepartmentId }
  if ($projectMove.Status -eq 200) { $ProjectDepartmentChanged = $true }
  Record "CEO can administer a marked project's department" ($projectMove.Status -eq 200 -and $projectMove.Data.project.department_id -eq $baseDepartmentId)
  foreach ($role in @("accountant")) {
    $denied = Call-Api $role "PATCH" "/api/projects/$($project.id)" @{ department_id = $baseDepartmentId }
    Record "$role cannot perform CEO-only project reassignment" ($denied.Status -eq 403)
  }
  $employeeProject = @((Get-ApiRows $projectList "projects") | Where-Object name -eq "[EIMS16 TEST] 2026-10-09B Employee Access Project") | Select-Object -First 1
  $employeeDenied = Call-Api "employee" "PATCH" "/api/projects/$($employeeProject.id)" @{ department_id = $baseDepartmentId }
  Record "Employee cannot perform project reassignment even on an accessible project" ($employeeDenied.Status -eq 403)
  $headOutside = Call-Api "department_head" "PATCH" "/api/projects/$($project.id)" @{ department_id = $baseDepartmentId }
  Record "Department Head cannot perform project department reassignment" ($headOutside.Status -eq 403)
  $projectRestore = Call-Api "ceo" "PATCH" "/api/projects/$($project.id)" @{ department_id = $project.department_id }
  if ($projectRestore.Status -eq 200) { $ProjectDepartmentChanged = $false }
  Record "CEO restores marked project department" ($projectRestore.Status -eq 200 -and $projectRestore.Data.project.department_id -eq $project.department_id)

  # Treasury has no test partition or account selector; the service requires
  # exactly one treasury row, so adding a test row would block or risk real funds.
  Write-Output "BLOCKED valid finance mutation: schema has no isolated test treasury; disbursement code requires exactly one treasury account. No treasury or transaction write was attempted."

  # Catalog metadata needs a direct PostgreSQL connection/SQL editor. This local
  # environment has no DB URL, psql, Supabase CLI, or SQL MCP connection.
  Write-Output "BLOCKED RLS catalog verification: no PostgreSQL connection or SQL metadata tool is configured. No database metadata was changed."

} catch {
  Write-Output "HARNESS STOPPED: prerequisite or safe fixture operation failed; details withheld."
  $script:Failures++
} finally {
  if ($EmployeePending -and $Tokens.ContainsKey("ceo")) {
    $restore = Call-Api "ceo" "PATCH" "/api/profiles/$($Accounts.employee.UserId)/approve" @{}
    if ($restore.Status -ne 200 -or $restore.Data.profile.status -ne "active") { Write-Output "FAIL pending profile restoration"; $Failures++ }
    else { Write-Output "PASS pending profile restored to active" }
  }
  if ($HeadAssigned -and $AdminDepartmentId -and $Tokens.ContainsKey("ceo")) {
    $clear = Call-Api "ceo" "PATCH" "/api/departments/$AdminDepartmentId/head" @{ head_id = $null }
    $restoreRole = Call-Api "ceo" "PATCH" "/api/profiles/$($Accounts.employee.UserId)" @{ role = "employee" }
    $restoreDepartment = Call-Api "ceo" "PATCH" "/api/profiles/$($Accounts.employee.UserId)" @{ department_id = $me.employee.department_id }
    if ($clear.Status -ne 200 -or $restoreRole.Status -ne 200 -or $restoreDepartment.Status -ne 200) { Write-Output "FAIL department head assignment restoration"; $Failures++ }
    else { $HeadAssigned = $false; Write-Output "PASS department head assignment restored" }
  }
  if ($EmployeeRoleChanged -and $Tokens.ContainsKey("ceo")) {
    $restore = Call-Api "ceo" "PATCH" "/api/profiles/$($Accounts.employee.UserId)" @{ role = "employee" }
    if ($restore.Status -ne 200) { Write-Output "FAIL Employee role restoration"; $Failures++ }
    else { Write-Output "PASS Employee role restored" }
  }
  if ($ProjectDepartmentChanged -and $ProjectIdUnderTest -and $Tokens.ContainsKey("ceo")) {
    $restore = Call-Api "ceo" "PATCH" "/api/projects/$ProjectIdUnderTest" @{ department_id = $OriginalProjectDepartmentId }
    if ($restore.Status -ne 200) { Write-Output "FAIL project department restoration"; $Failures++ }
    else { Write-Output "PASS project department restored" }
  }
  foreach ($role in @($Tokens.Keys)) { $Tokens[$role] = $null }
  $Tokens.Clear()
  foreach ($account in $Accounts.Values) { if ($account.Credential -and $account.Credential.Password) { $account.Credential.Password.Dispose() } }
  $anonKey = $null; $ServiceRoleKey = $null
  [GC]::Collect()
}

if ($Failures) { Write-Output "Gap-closure test run finished with $Failures failure(s)."; $global:LASTEXITCODE = 1; return }
Write-Output "Gap-closure test run finished; BLOCKED items remain unresolved."
$global:LASTEXITCODE = 0
