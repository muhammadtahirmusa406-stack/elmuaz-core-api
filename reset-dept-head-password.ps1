# reset-dept-head-password.ps1
# Targeted, non-destructive password reset for EIMS16 Department Head
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

function Get-DotEnvValue([string]$Key) {
  $line = Get-Content ".env" | Where-Object { $_ -match "^\s*$Key\s*=" } | Select-Object -First 1
  if ($line) { return ($line -split "=", 2)[1].Trim().Trim('"').Trim("'") }
  return $null
}

function New-RandomPassword {
  $bytes = [byte[]]::new(48)
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try {
    $rng.GetBytes($bytes)
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
  }
  finally {
    $rng.Dispose()
  }
}

if (-not (Test-Path -LiteralPath ".env")) {
  throw "Run from the backend root folder containing .env."
}

$supabaseUrl = (Get-DotEnvValue "SUPABASE_URL").TrimEnd('/')
$serviceKey  = Get-DotEnvValue "SUPABASE_SERVICE_ROLE_KEY"
if (-not $supabaseUrl -or -not $serviceKey) {
  throw "Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY in .env."
}

$deptHeadId = "e167e074-1c0f-406f-ba42-3ae1e41986b1"
$newPassword = New-RandomPassword

# Update Department Head via Supabase Admin API
$adminUri = "$supabaseUrl/auth/v1/admin/users/$deptHeadId"
$headers = @{
  "apikey"        = $serviceKey
  "Authorization" = "Bearer $serviceKey"
  "Content-Type"  = "application/json"
}

$body = @{
  password      = $newPassword
  email_confirm = $true
} | ConvertTo-Json -Compress

Write-Host "Updating password for Department Head ($deptHeadId)..."
$response = Invoke-RestMethod -Method Put -Uri $adminUri -Headers $headers -Body $body

if (-not $response.id) {
  throw "Failed to update Department Head password via Admin API."
}

# Update or create the DPAPI credential record
$credDir = Join-Path $env:LOCALAPPDATA "ELMUAZ"
$credPath = Join-Path $credDir "EIMS16-test-credentials.xml"

if (-not (Test-Path -LiteralPath $credDir)) {
  New-Item -ItemType Directory -Path $credDir -Force | Out-Null
}

$records = @()
if (Test-Path -LiteralPath $credPath) {
  try { $records = @(Import-Clixml -LiteralPath $credPath) } catch { $records = @() }
}

$existing = $records | Where-Object { $_.Role -eq "department_head" -or $_.UserId -eq $deptHeadId } | Select-Object -First 1
if ($existing) {
  $existing.Password = ($newPassword | ConvertTo-SecureString -AsPlainText -Force)
} else {
  $records += [pscustomobject]@{
    Role     = "department_head"
    Email    = "eims16-department-head@example.invalid"
    UserId   = $deptHeadId
    Password = ($newPassword | ConvertTo-SecureString -AsPlainText -Force)
  }
}

$records | Export-Clixml -LiteralPath $credPath -Depth 5 -Force

# Securely pipe to clipboard for immediate login
Set-Clipboard -Value $newPassword
$newPassword = $null
$serviceKey = $null

Write-Host "Success: Department Head password updated."
Write-Host "The new password has been copied to your clipboard."
Write-Host "Stored securely in DPAPI at: $credPath"
