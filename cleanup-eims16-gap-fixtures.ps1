# Prepared local-only cleanup for fixtures created by test-eims16-gap-closure.ps1.
# Preview is the default. Pass -Execute to perform the two exact, guarded deletes.
# This script never deletes test Auth users or modifies profiles, projects, tasks,
# treasury, transactions, audit logs, or fixtures from earlier EIMS16 runs.
param(
  [string]$BaseUrl = "http://localhost:5000",
  [switch]$Execute
)
$ErrorActionPreference = "Stop"
$ExpectedProjectHost = "rtxmjyenehsjtsccnbxs.supabase.co"
$CredentialPath = Join-Path $env:LOCALAPPDATA "ELMUAZ\EIMS16-test-credentials.xml"
$DepartmentId = "4fca20e1-001d-413a-9fe0-1e823e770030"
$DepartmentName = "TEST EIMS16 Admin Mutation 2026-10-09 Verified"
$DepartmentCode = "E16ADMIN1009"
$NotificationId = "babc74ee-9b18-470b-b343-adf0b0bc2ae3"
$NotificationTitle = "[EIMS16 TEST] ownership 2026-10-09"
$NotificationMessage = "Dedicated EIMS #16 notification ownership fixture."
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

try {
  if (-not (Test-Path -LiteralPath ".env") -or -not (Test-Path -LiteralPath $CredentialPath)) { throw "Local config or DPAPI credential store is missing." }
  $supabaseUrl = (Get-DotEnvValue "SUPABASE_URL").TrimEnd('/')
  $anonKey = Get-DotEnvValue "SUPABASE_ANON_KEY"
  $serviceRoleKey = Get-DotEnvValue "SUPABASE_SERVICE_ROLE_KEY"
  if (-not $supabaseUrl -or ([uri]$supabaseUrl).Host -ne $ExpectedProjectHost -or -not $anonKey -or -not $serviceRoleKey) {
    throw "Configured project or local keys do not match the verified development project."
  }

  $records = @(Import-Clixml -LiteralPath $CredentialPath)
  $ceo = @($records | Where-Object Role -eq "ceo")
  $employee = @($records | Where-Object Role -eq "employee")
  if ($ceo.Count -ne 1 -or $employee.Count -ne 1) { throw "Dedicated CEO/Employee credential records are missing." }
  $password = $ceo[0].Credential.GetNetworkCredential().Password
  try {
    $loginBody = @{ email = $ceo[0].Credential.UserName; password = $password } | ConvertTo-Json -Compress
    $login = Invoke-RestMethod -Uri "$supabaseUrl/auth/v1/token?grant_type=password" -Method Post `
      -Headers @{ apikey = $anonKey } -ContentType "application/json" -Body $loginBody -TimeoutSec 25
    $ceoToken = $login.access_token
  } finally { $password = $null; $loginBody = $null; if ($ceo[0].Credential.Password) { $ceo[0].Credential.Password.Dispose() } }
  $apiHeaders = @{ Authorization = "Bearer $ceoToken" }
  $serviceHeaders = @{ apikey = $serviceRoleKey; Authorization = "Bearer $serviceRoleKey" }

  # Verify department identity and ensure no profile/project currently refers to it.
  $departmentResponse = Invoke-RestMethod -Uri "$BaseUrl/api/departments/$DepartmentId" -Headers $apiHeaders -TimeoutSec 25
  $department = $departmentResponse.department
  if ($department.id -ne $DepartmentId -or $department.name -ne $DepartmentName -or $department.code -ne $DepartmentCode -or $department.head_id) {
    throw "Department identity/head guard failed; no cleanup writes were performed."
  }
  # Build query URLs from single-quoted format strings so PowerShell treats
  # every query separator as URL data, then encode dynamic filter values.
  $encodedDepartmentId = [uri]::EscapeDataString($DepartmentId)
  $profileRefsUri = ('{0}/rest/v1/profiles?select=id&department_id=eq.{1}' -f $supabaseUrl, $encodedDepartmentId)
  $projectRefsUri = ('{0}/rest/v1/projects?select=id&department_id=eq.{1}' -f $supabaseUrl, $encodedDepartmentId)
  $profileRefs = Invoke-RestMethod -Uri $profileRefsUri -Headers $serviceHeaders -TimeoutSec 25
  $projectRefs = Invoke-RestMethod -Uri $projectRefsUri -Headers $serviceHeaders -TimeoutSec 25
  if (@($profileRefs).Count -ne 0 -or @($projectRefs).Count -ne 0) { throw "Department is still referenced; no cleanup writes were performed." }
  $encodedEmployeeId = [uri]::EscapeDataString([string]$employee[0].UserId)
  $employeeProfileUri = ('{0}/rest/v1/profiles?select=id,role,status,department_id&id=eq.{1}' -f $supabaseUrl, $encodedEmployeeId)
  $employeeProfile = Invoke-RestMethod -Uri $employeeProfileUri -Headers $serviceHeaders -TimeoutSec 25
  if (@($employeeProfile).Count -ne 1 -or $employeeProfile[0].role -ne "employee" -or $employeeProfile[0].status -ne "active" -or
      $employeeProfile[0].department_id -ne "f21e1955-af29-4e1e-b716-76640c1d1b12") {
    throw "Dedicated Employee profile is not in its restored state; no cleanup writes were performed."
  }

  # Verify the exact notification row, ownership, and marker before any delete.
  $employeeId = $employee[0].UserId
  $encodedNotificationId = [uri]::EscapeDataString($NotificationId)
  $encodedEmployeeId = [uri]::EscapeDataString([string]$employeeId)
  $notificationRowsUri = ('{0}/rest/v1/notifications?select=id,profile_id,title,message,type&id=eq.{1}&profile_id=eq.{2}' -f $supabaseUrl, $encodedNotificationId, $encodedEmployeeId)
  $notificationRows = Invoke-RestMethod -Uri $notificationRowsUri `
    -Headers $serviceHeaders -TimeoutSec 25
  if (@($notificationRows).Count -ne 1 -or $notificationRows[0].id -ne $NotificationId -or
      $notificationRows[0].title -ne $NotificationTitle -or $notificationRows[0].message -ne $NotificationMessage -or
      $notificationRows[0].type -ne "general") {
    throw "Notification identity/ownership guard failed; no cleanup writes were performed."
  }

  Write-Output ('Verified exact cleanup targets: notification {0}; department {1}.' -f $NotificationId, $DepartmentId)
  if (-not $Execute) {
    Write-Output "PREVIEW ONLY - no records were deleted. Re-run with -Execute only when cleanup is wanted."
    return
  }

  $notificationDeleteUri = ('{0}/rest/v1/notifications?id=eq.{1}&profile_id=eq.{2}' -f $supabaseUrl, $encodedNotificationId, $encodedEmployeeId)
  $notificationDelete = Invoke-WebRequest -Uri $notificationDeleteUri `
    -Method Delete -Headers ($serviceHeaders + @{ Prefer = "return=representation" }) -TimeoutSec 25
  $deletedNotification = if ($notificationDelete.Content) { @($notificationDelete.Content | ConvertFrom-Json) } else { @() }
  if ($deletedNotification.Count -ne 1 -or $deletedNotification[0].id -ne $NotificationId) { throw "Notification cleanup did not remove exactly the targeted row." }

  $departmentDelete = Invoke-WebRequest -Uri "$BaseUrl/api/departments/$DepartmentId" -Method Delete -Headers $apiHeaders -TimeoutSec 25
  $departmentDeleteBody = $departmentDelete.Content | ConvertFrom-Json
  if ([int]$departmentDelete.StatusCode -ne 200 -or $departmentDeleteBody.department.id -ne $DepartmentId) {
    throw 'Department cleanup did not confirm deletion of the targeted department.'
  }
  Write-Output 'PASS removed only the marked notification and unreferenced marked department.'
} finally {
  if ($login) { $login.access_token = ""; $login.refresh_token = "" }
  $login = $null; $ceoToken = $null; $anonKey = $null; $serviceRoleKey = $null
  foreach ($record in @($ceo) + @($employee)) { if ($record.Credential -and $record.Credential.Password) { $record.Credential.Password.Dispose() } }
  [GC]::Collect()
}
