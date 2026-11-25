$ErrorActionPreference = "Stop"

function Get-DotEnvValue([string]$Name) {
    $line = Get-Content -LiteralPath ".env" |
        Where-Object { $_ -match "^\s*$([regex]::Escape($Name))\s*=" } |
        Select-Object -First 1

    if (-not $line) { return $null }

    $value = ($line -replace "^\s*$([regex]::Escape($Name))\s*=\s*", "").Trim()

    if ($value.Length -ge 2 -and
        (($value.StartsWith('"') -and $value.EndsWith('"')) -or
         ($value.StartsWith("'") -and $value.EndsWith("'")))) {
        return $value.Substring(1, $value.Length - 2)
    }

    return ($value -replace '\s+#.*$', '').Trim()
}

$supabaseUrl = (Get-DotEnvValue "SUPABASE_URL").TrimEnd("/")
$serviceKey = Get-DotEnvValue "SUPABASE_SERVICE_ROLE_KEY"

if (-not $supabaseUrl -or -not $serviceKey) {
    throw "Supabase configuration is missing."
}

if (([uri]$supabaseUrl).Host -ne "rtxmjyenehsjtsccnbxs.supabase.co") {
    throw "Unexpected Supabase project. Stopping."
}

$headers = @{
    apikey        = $serviceKey
    Authorization = "Bearer $serviceKey"
}

$employeeId = "a41341c2-06e3-4b0c-ae2b-4cfe2dcef5b6"
$uri = "$supabaseUrl/rest/v1/profiles?select=id,role,status,department_id&id=eq.$employeeId"

try {
    $response = Invoke-WebRequest -Uri $uri -Headers $headers -TimeoutSec 25
    $rows = @(ConvertFrom-Json -InputObject $response.Content)

    Write-Host "`n=== EMPLOYEE PROFILE VERIFICATION ===" -ForegroundColor Cyan
    Write-Host "Rows found: $($rows.Count)"

    foreach ($row in $rows) {
        Write-Host "ID: $($row.id)"
        Write-Host "Role: $($row.role)"
        Write-Host "Status: $($row.status)"
        Write-Host "Department ID: $($row.department_id)"
    }

    if ($rows.Count -eq 1 -and
        $rows[0].role -eq "employee" -and
        $rows[0].status -eq "active" -and
        $rows[0].department_id -eq "f21e1955-af29-4e1e-b716-76640c1d1b12") {
        Write-Host "`nPASS: Employee profile matches the expected restored state." -ForegroundColor Green
    } else {
        Write-Host "`nSTOP: Employee profile differs from the expected state. Do not delete anything." -ForegroundColor Yellow
    }
}
finally {
    $headers = $null
    $serviceKey = $null
}
