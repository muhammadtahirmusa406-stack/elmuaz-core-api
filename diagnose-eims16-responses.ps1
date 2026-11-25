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

$checks = @(
    @{
        Name = "Department"
        Uri  = "$supabaseUrl/rest/v1/departments?select=id,name,code,head_id&id=eq.4fca20e1-001d-413a-9fe0-1e823e770030"
    },
    @{
        Name = "Notification"
        Uri  = "$supabaseUrl/rest/v1/notifications?select=id,profile_id,title,message,type&id=eq.babc74ee-9b18-470b-b343-adf0b0bc2ae3"
    },
    @{
        Name = "Department profile references"
        Uri  = "$supabaseUrl/rest/v1/profiles?select=id,department_id&department_id=eq.4fca20e1-001d-413a-9fe0-1e823e770030"
    },
    @{
        Name = "Department project references"
        Uri  = "$supabaseUrl/rest/v1/projects?select=id,department_id&department_id=eq.4fca20e1-001d-413a-9fe0-1e823e770030"
    }
)

try {
    foreach ($check in $checks) {
        Write-Host "`n=== $($check.Name) ===" -ForegroundColor Cyan

        try {
            $result = Invoke-RestMethod -Uri $check.Uri -Headers $headers -TimeoutSec 25
            Write-Host "Response type: $($result.GetType().FullName)"

            if ($result -is [string]) {
                Write-Host "Response text (first 300 characters):"
                Write-Host $result.Substring(0, [Math]::Min(300, $result.Length))
            } else {
                Write-Host "Response data:"
                ConvertTo-Json -InputObject $result -Depth 5
            }
        } catch {
            Write-Host "Request failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
} finally {
    $headers = $null
    $serviceKey = $null
}
