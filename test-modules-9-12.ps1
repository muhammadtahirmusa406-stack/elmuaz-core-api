# Credential-free local smoke test for the authentication boundary of modules 9–12.
# Run from the repository root while the backend is listening at the configured URL.
param([string]$BaseUrl = "http://localhost:5000")
$ErrorActionPreference = "Stop"
$checks = @(
  @{ Name = "GET meetings requires authentication"; Method = "GET"; Path = "/api/meetings" },
  @{ Name = "POST meetings requires authentication"; Method = "POST"; Path = "/api/meetings"; Body = '{"topic":"unauthenticated","meeting_time":"2030-01-01T12:00:00Z"}' },
  @{ Name = "GET announcements requires authentication"; Method = "GET"; Path = "/api/announcements" },
  @{ Name = "POST announcement acknowledgment requires authentication"; Method = "POST"; Path = "/api/announcements/00000000-0000-4000-8000-000000000001/acknowledge"; Body = "{}" },
  @{ Name = "GET notifications requires authentication"; Method = "GET"; Path = "/api/notifications" },
  @{ Name = "PATCH notification mark-read requires authentication"; Method = "PATCH"; Path = "/api/notifications/mark-read"; Body = '{"notification_ids":["00000000-0000-4000-8000-000000000001"]}' },
  @{ Name = "GET audit logs requires authentication"; Method = "GET"; Path = "/api/audit-logs" },
  @{ Name = "Existing GET tasks still requires authentication"; Method = "GET"; Path = "/api/tasks" }
)

$failed = $false
foreach ($check in $checks) {
  $actualStatus = 0
  try {
    $request = @{ Uri = "$BaseUrl$($check.Path)"; Method = $check.Method; TimeoutSec = 10 }
    if ($check.ContainsKey("Body")) {
      $request.ContentType = "application/json"
      $request.Body = $check.Body
    }
    $response = Invoke-WebRequest @request
    $actualStatus = [int]$response.StatusCode
  } catch {
    if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
      $actualStatus = [int]$_.Exception.Response.StatusCode
    }
  }
  if ($actualStatus -eq 401) {
    Write-Output "PASS $($check.Name)"
  } else {
    Write-Output "FAIL $($check.Name) (HTTP $actualStatus)"
    $failed = $true
  }
}

if ($failed) { exit 1 }
