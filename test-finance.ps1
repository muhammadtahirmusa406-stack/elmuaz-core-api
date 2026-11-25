# Local-only finance smoke test. By default, checks unauthenticated boundaries.
# Add -Authenticated to sign in interactively using only SUPABASE_URL and
# SUPABASE_ANON_KEY from .env. Credentials and tokens are not printed or written.
param(
  [string]$BaseUrl = "http://localhost:5000",
  [switch]$Authenticated
)
$ErrorActionPreference = "Stop"

function Get-DotEnvValue([string]$Name) {
  $content = Get-Content -LiteralPath ".env" -Raw
  $match = [regex]::Match($content, "(?m)^\s*$([regex]::Escape($Name))\s*=\s*(.*?)\s*$")
  if (-not $match.Success) { return $null }
  $value = $match.Groups[1].Value.Trim()
  if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) {
    $value = $value.Substring(1, $value.Length - 2)
  }
  return $value
}

function Get-StatusCode($ErrorRecord) {
  if ($ErrorRecord.Exception.Response -and $ErrorRecord.Exception.Response.StatusCode) {
    return [int]$ErrorRecord.Exception.Response.StatusCode
  }
  return 0
}

function Invoke-Api([string]$Method, [string]$Path, [string]$Token, $Body) {
  $request = @{ Uri = "$BaseUrl$Path"; Method = $Method; TimeoutSec = 15 }
  if ($Token) { $request.Headers = @{ Authorization = "Bearer $Token" } }
  if ($null -ne $Body) { $request.ContentType = "application/json"; $request.Body = $Body | ConvertTo-Json -Compress -Depth 5 }
  try {
    $response = Invoke-RestMethod @request
    return @{ Status = 200; Data = $response }
  } catch {
    return @{ Status = (Get-StatusCode $_); Data = $null }
  }
}

if (-not (Test-Path -LiteralPath ".env")) { throw "Run from the project root containing .env." }
$checks = @(
  @{ Name = "Unauthenticated finance metrics returns 401"; Method = "GET"; Path = "/api/finance/metrics" },
  @{ Name = "Unauthenticated finance transactions returns 401"; Method = "GET"; Path = "/api/finance/transactions" },
  @{ Name = "Unauthenticated finance disbursement returns 401"; Method = "POST"; Path = "/api/finance/disburse"; Body = @{ recipient_id = "00000000-0000-4000-8000-000000000001"; amount = "1.00"; payment_type = "salary" } }
)
$failed = $false
foreach ($check in $checks) {
  $body = if ($check.ContainsKey("Body")) { $check.Body } else { $null }
  $result = Invoke-Api $check.Method $check.Path $null $body
  if ($result.Status -eq 401) { Write-Output "PASS $($check.Name)" }
  else { Write-Output "FAIL $($check.Name) (HTTP $($result.Status))"; $failed = $true }
}

$email = $null
$password = $null
$token = $null
try {
  if ($Authenticated) {
    $supabaseUrl = Get-DotEnvValue "SUPABASE_URL"
    $anonKey = Get-DotEnvValue "SUPABASE_ANON_KEY"
    if (-not $supabaseUrl -or -not $anonKey) { throw "SUPABASE_URL or SUPABASE_ANON_KEY is missing from .env." }
    $email = Read-Host "Finance test-user email"
    $securePassword = Read-Host "Finance test-user password (hidden)" -AsSecureString
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    try { $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer); $securePassword.Dispose() }

    try {
      $authResponse = Invoke-RestMethod -Uri "$($supabaseUrl.TrimEnd('/'))/auth/v1/token?grant_type=password" `
        -Method Post -Headers @{ apikey = $anonKey } -ContentType "application/json" `
        -Body (@{ email = $email; password = $password } | ConvertTo-Json -Compress) -TimeoutSec 20
      $token = $authResponse.access_token
    } catch {
      Write-Output "FAIL Interactive Supabase sign-in (credentials/provider details withheld)"
      $failed = $true
    }

    if ($token) {
      $me = Invoke-Api "GET" "/api/me" $token $null
      if ($me.Status -eq 200 -and $me.Data.profile.role -in @("ceo", "accountant")) {
        foreach ($endpoint in @(
          @{ Name = "Authorized finance metrics"; Method = "GET"; Path = "/api/finance/metrics" },
          @{ Name = "Authorized finance transaction listing"; Method = "GET"; Path = "/api/finance/transactions" }
        )) {
          $result = Invoke-Api $endpoint.Method $endpoint.Path $token $null
          if ($result.Status -eq 200) { Write-Output "PASS $($endpoint.Name)" }
          else { Write-Output "FAIL $($endpoint.Name) (HTTP $($result.Status))"; $failed = $true }
        }
        $invalidAmount = Invoke-Api "POST" "/api/finance/disburse" $token @{
          recipient_id = "00000000-0000-4000-8000-000000000001"
          amount = "0.00"
          payment_type = "salary"
        }
        if ($invalidAmount.Status -eq 400) { Write-Output "PASS Zero disbursement amount rejected" }
        else { Write-Output "FAIL Zero disbursement amount rejected (HTTP $($invalidAmount.Status))"; $failed = $true }
      } elseif ($me.Status -eq 200 -and $me.Data.profile.role -in @("employee", "department_head")) {
        foreach ($endpoint in @(
          @{ Name = "Employee/Department Head finance metrics denied"; Method = "GET"; Path = "/api/finance/metrics" },
          @{ Name = "Employee/Department Head finance transactions denied"; Method = "GET"; Path = "/api/finance/transactions" },
          @{ Name = "Employee/Department Head disbursement denied"; Method = "POST"; Path = "/api/finance/disburse"; Body = @{ recipient_id = "00000000-0000-4000-8000-000000000001"; amount = "1.00"; payment_type = "salary" } }
        )) {
          $body = if ($endpoint.ContainsKey("Body")) { $endpoint.Body } else { $null }
          $result = Invoke-Api $endpoint.Method $endpoint.Path $token $body
          if ($result.Status -eq 403) { Write-Output "PASS $($endpoint.Name)" }
          else { Write-Output "FAIL $($endpoint.Name) (HTTP $($result.Status))"; $failed = $true }
        }
      } else {
        Write-Output "FAIL Finance test-user profile unavailable or role unsupported"
        $failed = $true
      }
    }
  }
} finally {
  $email = $null
  $password = $null
  $token = $null
  $authResponse = $null
  $anonKey = $null
  [GC]::Collect()
}

if ($failed) { exit 1 }
