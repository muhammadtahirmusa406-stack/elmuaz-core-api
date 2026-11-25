# Local-only EIMS authentication smoke test.
# Uses SUPABASE_URL and SUPABASE_ANON_KEY from .env plus an existing test user's
# credentials entered at the terminal. Tokens and credentials stay in memory.

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath ".env")) {
  throw "Run this script from the project root, where .env is located."
}

$email = Read-Host "Supabase test-user email"
$securePassword = Read-Host "Supabase test-user password" -AsSecureString
$passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)

try {
  $env:EIMS_TEST_EMAIL = $email
  $env:EIMS_TEST_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)

  $js = @'
import { config } from "dotenv";
import { createClient } from "@supabase/supabase-js";

config({ path: ".env", quiet: true });
const { SUPABASE_URL, SUPABASE_ANON_KEY } = process.env;
const { EIMS_TEST_EMAIL, EIMS_TEST_PASSWORD } = process.env;
if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !EIMS_TEST_EMAIL || !EIMS_TEST_PASSWORD) {
  console.log("Test not run: required local configuration is missing.");
  process.exitCode = 2;
} else {
  const authClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const redact = (value) => {
    let safe = String(value ?? "");
    for (const secret of [EIMS_TEST_PASSWORD, SUPABASE_ANON_KEY, process.env.SUPABASE_SERVICE_ROLE_KEY]) {
      if (secret) safe = safe.split(secret).join("[REDACTED]");
    }
    if (EIMS_TEST_EMAIL) safe = safe.split(EIMS_TEST_EMAIL).join("[REDACTED EMAIL]");
    return safe
      .replace(/Bearer\s+[^\s,;]+/gi, "Bearer [REDACTED]")
      .replace(/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g, "[REDACTED TOKEN]")
      .replace(/(password|access[_ -]?token|refresh[_ -]?token|service[_ -]?role[_ -]?key)\s*[:=]\s*[^\s,;]+/gi, "$1=[REDACTED]")
      .slice(0, 300);
  };

  try {
    const { data, error } = await authClient.auth.signInWithPassword({
      email: EIMS_TEST_EMAIL,
      password: EIMS_TEST_PASSWORD,
    });
    if (error || !data.session?.access_token) {
      const detail = error
        ? [error.code && `code=${redact(error.code)}`, error.status && `status=${error.status}`, error.message && `message=${redact(error.message)}`].filter(Boolean).join("; ")
        : "Supabase returned no session";
      console.log(`Supabase sign-in failed: ${detail || "no safe diagnostic was returned"}`);
      process.exitCode = 1;
    } else {
      try {
        const response = await fetch("http://localhost:5000/api/me", {
          headers: { Authorization: `Bearer ${data.session.access_token}` },
        });
        let body;
        try { body = await response.json(); } catch { body = undefined; }
        const ok = response.ok && body?.success === true && Boolean(body?.profile);
        console.log(`GET /api/me: HTTP ${response.status}; profile returned: ${ok}`);
        process.exitCode = ok ? 0 : 1;
      } catch {
        console.log("GET /api/me failed; local server details were withheld.");
        process.exitCode = 1;
      } finally {
        data.session.access_token = "";
        data.session.refresh_token = "";
      }
    }
  } catch {
    console.log("Supabase sign-in failed: safe error details unavailable.");
    process.exitCode = 1;
  } finally {
    await authClient.auth.dispose().catch(() => {});
  }
}
'@

  # A temporary module file avoids PowerShell native-argument quoting differences
  # around multiline JavaScript passed to `node -e`.
  $jsPath = Join-Path (Get-Location) ".eims-auth-test-$PID.mjs"
  [IO.File]::WriteAllText($jsPath, $js, [Text.UTF8Encoding]::new($false))
  node $jsPath
  $nodeExitCode = $LASTEXITCODE
}
finally {
  if ($jsPath) {
    Remove-Item -LiteralPath $jsPath -Force -ErrorAction SilentlyContinue
  }
  Remove-Item Env:EIMS_TEST_EMAIL -ErrorAction SilentlyContinue
  Remove-Item Env:EIMS_TEST_PASSWORD -ErrorAction SilentlyContinue
  [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
  $securePassword.Dispose()
}

if ($nodeExitCode -ne 0) {
  exit $nodeExitCode
}
