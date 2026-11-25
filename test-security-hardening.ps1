# Local-only checks for safe request parsing and generic route/error responses.
param([string]$BaseUrl = "http://localhost:5000")
$ErrorActionPreference = "Stop"
$failed = $false

function Test-Status([string]$Name, [string]$Method, [string]$Path, [int]$Expected, [string]$Authorization = $null, [string]$Body = $null) {
  $request = @{ Uri = "$BaseUrl$Path"; Method = $Method; TimeoutSec = 10 }
  if ($Authorization) { $request.Headers = @{ Authorization = $Authorization } }
  if ($null -ne $Body) { $request.ContentType = "application/json"; $request.Body = $Body }
  $status = 0
  $responseBody = ""
  try {
    $response = Invoke-WebRequest @request
    $status = [int]$response.StatusCode
    $responseBody = [string]$response.Content
  } catch {
    if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
      $status = [int]$_.Exception.Response.StatusCode
      try {
        if ($_.ErrorDetails.Message) {
          $responseBody = $_.ErrorDetails.Message
        } elseif ($_.Exception.Response -is [System.Net.Http.HttpResponseMessage]) {
          $responseBody = $_.Exception.Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        } else {
          $reader = [IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
          try { $responseBody = $reader.ReadToEnd() } finally { $reader.Dispose() }
        }
      } catch { $responseBody = "" }
    }
  }
  $passed = $status -eq $Expected
  if ($Name -eq "Malformed JSON returns a safe client error") {
    $passed = $passed -and $responseBody -match '"success"\s*:\s*false' -and
      $responseBody.Contains("Malformed JSON request body") -and
      -not $responseBody.Contains("SyntaxError") -and -not $responseBody.Contains("stack")
  }
  if ($Name -eq "Unknown route returns JSON 404") {
    $passed = $passed -and $responseBody -match '"success"\s*:\s*false' -and $responseBody.Contains("Route not found")
  }
  if ($passed) { Write-Output "PASS $Name" }
  else { Write-Output "FAIL $Name (HTTP $status)"; $script:failed = $true }
}

Test-Status "Missing bearer token returns 401" "GET" "/api/me" 401
Test-Status "Malformed bearer header returns 401" "GET" "/api/me" 401 "Bearer"
Test-Status "Malformed JSON returns a safe client error" "POST" "/api/finance/disburse" 400 $null "{"
Test-Status "Unknown route returns JSON 404" "GET" "/api/security-hardening-unknown" 404

if ($failed) { exit 1 }
