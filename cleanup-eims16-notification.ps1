param(
    [switch]$Execute
)

$ErrorActionPreference = "Stop"

$envPath = Join-Path $PSScriptRoot ".env"

if (-not (Test-Path -LiteralPath $envPath)) {
    throw "Missing .env file. Nothing was changed."
}

$envLines = Get-Content -LiteralPath $envPath

$envMap = @{}
foreach ($line in $envLines) {
    if ($line -match '^\s*([^#=]+?)\s*=\s*(.*?)\s*$') {
        $envMap[$matches[1].Trim()] = $matches[2].Trim().Trim('"').Trim("'")
    }
}

$url = $envMap["SUPABASE_URL"]
if (-not $url) {
    $url = $envMap["NEXT_PUBLIC_SUPABASE_URL"]
}
if (-not $url) {
    throw "Supabase URL not found. Nothing was changed."
}

$key = $envMap["SUPABASE_SERVICE_ROLE_KEY"]
if (-not $key) {
    $key = $envMap["SUPABASE_SERVICE_KEY"]
}
if (-not $key) {
    throw "Service-role key not found in .env. Nothing was changed."
}

$expectedId = "babc74ee-9b18-470b-b343-adf0b0bc2ae3"
$expectedProfileId = "a41341c2-06e3-4b0c-ae2b-4cfe2dcef5b6"
$expectedTitle = "[EIMS16 TEST] ownership 2026-10-09"
$expectedMessage = "Dedicated EIMS #16 notification ownership fixture."
$expectedType = "general"

$headers = @{
    apikey        = $key
    Authorization = "Bearer $key"
    Accept        = "application/json"
}

$baseUrl = $url.TrimEnd("/") + "/rest/v1/notifications"
$queryUrl = $baseUrl + "?id=eq." + $expectedId + "&select=id,profile_id,title,message,type"

$rows = @(Invoke-RestMethod -Uri $queryUrl -Method Get -Headers $headers)

if ($rows.Count -ne 1) {
    throw "Safety stop: expected exactly one matching notification ID; found $($rows.Count). Nothing was changed."
}

$row = $rows[0]

if (
    [string]$row.id -ne $expectedId -or
    [string]$row.profile_id -ne $expectedProfileId -or
    [string]$row.title -ne $expectedTitle -or
    [string]$row.message -ne $expectedMessage -or
    [string]$row.type -ne $expectedType
) {
    throw "Safety stop: notification fields do not match the verified fixture. Nothing was changed."
}

Write-Host ""
Write-Host "Verified exact notification fixture:" -ForegroundColor Cyan
Write-Host "ID:      $($row.id)"
Write-Host "Profile: $($row.profile_id)"
Write-Host "Title:   $($row.title)"
Write-Host ""

if (-not $Execute) {
    Write-Host "PREVIEW ONLY: no data was deleted." -ForegroundColor Yellow
    Write-Host "If the details above are correct, run this script again with -Execute."
    exit 0
}

$deleteUrl = $baseUrl + "?id=eq." + $expectedId
$deleteHeaders = @{
    apikey        = $key
    Authorization = "Bearer $key"
    Accept        = "application/json"
    Prefer        = "return=representation"
}

$deleted = @(Invoke-RestMethod -Uri $deleteUrl -Method Delete -Headers $deleteHeaders)

if ($deleted.Count -ne 1 -or [string]$deleted[0].id -ne $expectedId) {
    throw "Unexpected deletion response. Stop and verify the notification directly in Supabase."
}

$remaining = @(Invoke-RestMethod -Uri $queryUrl -Method Get -Headers $headers)

if ($remaining.Count -ne 0) {
    throw "Deletion response was received, but the fixture still appears in the verification query. Check Supabase before doing anything else."
}

Write-Host "SUCCESS: only the verified test notification was deleted." -ForegroundColor Green
Write-Host "A follow-up query confirmed that the fixture is no longer present."
