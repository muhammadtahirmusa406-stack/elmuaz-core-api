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

try {
    $supabaseUrl = (Get-DotEnvValue "SUPABASE_URL").TrimEnd("/")
    $serviceKey = Get-DotEnvValue "SUPABASE_SERVICE_ROLE_KEY"

    if (-not $supabaseUrl -or -not $serviceKey) {
        throw "Supabase URL or service-role configuration is missing."
    }

    if (([uri]$supabaseUrl).Host -ne "rtxmjyenehsjtsccnbxs.supabase.co") {
        throw "The configured project does not match the verified development project."
    }

    $headers = @{
        apikey        = $serviceKey
        Authorization = "Bearer $serviceKey"
    }

    $departmentId = "4fca20e1-001d-413a-9fe0-1e823e770030"
    $notificationId = "babc74ee-9b18-470b-b343-adf0b0bc2ae3"
    $employeeId = "a41341c2-06e3-4b0c-ae2b-4cfe2dcef5b6"

    $department = @(Invoke-RestMethod -Uri "$supabaseUrl/rest/v1/departments?select=id,name,code,head_id&id=eq.$departmentId" -Headers $headers -TimeoutSec 25)
    $notification = @(Invoke-RestMethod -Uri "$supabaseUrl/rest/v1/notifications?select=id,profile_id,title,message,type&id=eq.$notificationId" -Headers $headers -TimeoutSec 25)
    $profileRefs = @(Invoke-RestMethod -Uri "$supabaseUrl/rest/v1/profiles?select=id,department_id&department_id=eq.$departmentId" -Headers $headers -TimeoutSec 25)
    $projectRefs = @(Invoke-RestMethod -Uri "$supabaseUrl/rest/v1/projects?select=id,department_id&department_id=eq.$departmentId" -Headers $headers -TimeoutSec 25)
    $employee = @(Invoke-RestMethod -Uri "$supabaseUrl/rest/v1/profiles?select=id,role,status,department_id&id=eq.$employeeId" -Headers $headers -TimeoutSec 25)

    Write-Host "`n=== READ-ONLY VERIFICATION RESULTS ===" -ForegroundColor Cyan
    Write-Host "`nDepartment:"
    $department | Select-Object id, name, code, head_id | Format-List
    Write-Host "Department rows found: $($department.Count)"

    Write-Host "`nNotification:"
    $notification | Select-Object id, profile_id, title, message, type | Format-List
    Write-Host "Notification rows found: $($notification.Count)"

    Write-Host "`nDepartment references:"
    Write-Host "Profiles: $($profileRefs.Count)"
    Write-Host "Projects: $($projectRefs.Count)"

    Write-Host "`nEmployee profile:"
    $employee | Select-Object id, role, status, department_id | Format-List
    Write-Host "Employee rows found: $($employee.Count)"

    Write-Host "`nVerification complete. No records were modified." -ForegroundColor Green
}
catch {
    Write-Host "Verification failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "No deletion was attempted."
}
finally {
    $headers = $null
    $serviceKey = $null
}
