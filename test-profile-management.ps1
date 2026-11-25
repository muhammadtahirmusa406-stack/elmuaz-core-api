# Local-only profile-management integration smoke test.
# Requires a running backend, a CEO test account, an employee test account,
# and a designated pending profile that is safe to activate during this test.

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath ".env")) {
  throw "Run this script from the project root, where .env is located."
}

function Read-HiddenValue([string]$Prompt) {
  $secureValue = Read-Host $Prompt -AsSecureString
  $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureValue)
  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
  }
  finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    $secureValue.Dispose()
  }
}

$ceoEmail = Read-HiddenValue "CEO test-user email (hidden)"
$ceoPassword = Read-HiddenValue "CEO test-user password (hidden)"
$employeeEmail = Read-HiddenValue "Employee test-user email (hidden)"
$employeePassword = Read-HiddenValue "Employee test-user password (hidden)"
$pendingProfileId = Read-Host "UUID of designated pending test profile (CEO approval will activate it)"

try {
  $env:EIMS_TEST_CEO_EMAIL = $ceoEmail
  $env:EIMS_TEST_CEO_PASSWORD = $ceoPassword
  $env:EIMS_TEST_EMPLOYEE_EMAIL = $employeeEmail
  $env:EIMS_TEST_EMPLOYEE_PASSWORD = $employeePassword
  $env:EIMS_TEST_PENDING_PROFILE_ID = $pendingProfileId

  $js = @'
import { config } from "dotenv";
import { createClient } from "@supabase/supabase-js";

const localEnv = {};
config({ path: ".env", quiet: true, processEnv: localEnv });
const { SUPABASE_URL, SUPABASE_ANON_KEY } = localEnv;
const { EIMS_TEST_CEO_EMAIL, EIMS_TEST_CEO_PASSWORD, EIMS_TEST_EMPLOYEE_EMAIL,
  EIMS_TEST_EMPLOYEE_PASSWORD, EIMS_TEST_PENDING_PROFILE_ID } = process.env;
const results = [];
const record = (name, passed) => results.push({ name, passed: Boolean(passed) });
const json = (value) => JSON.stringify(value);

async function signIn(email, password) {
  const client = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data, error } = await client.auth.signInWithPassword({ email, password });
  return { client, data, error };
}

async function api(baseUrl, token, method, path, body) {
  const response = await fetch(`${baseUrl}${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      ...(body === undefined ? {} : { "Content-Type": "application/json" }),
    },
    ...(body === undefined ? {} : { body: json(body) }),
  });
  let payload;
  try { payload = await response.json(); } catch { payload = undefined; }
  return { status: response.status, payload };
}

let ceo;
let employee;
try {
  const configOk = Boolean(SUPABASE_URL && SUPABASE_ANON_KEY && EIMS_TEST_CEO_EMAIL &&
    EIMS_TEST_CEO_PASSWORD && EIMS_TEST_EMPLOYEE_EMAIL && EIMS_TEST_EMPLOYEE_PASSWORD &&
    EIMS_TEST_PENDING_PROFILE_ID);
  if (!configOk) {
    record("Local configuration", false);
  } else {
    const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
    record("Pending test profile ID format", uuidPattern.test(EIMS_TEST_PENDING_PROFILE_ID));
    if (uuidPattern.test(EIMS_TEST_PENDING_PROFILE_ID)) {
      ceo = await signIn(EIMS_TEST_CEO_EMAIL, EIMS_TEST_CEO_PASSWORD);
      employee = await signIn(EIMS_TEST_EMPLOYEE_EMAIL, EIMS_TEST_EMPLOYEE_PASSWORD);
      record("CEO test-user sign-in", !ceo.error && Boolean(ceo.data.session?.access_token));
      record("Employee test-user sign-in", !employee.error && Boolean(employee.data.session?.access_token));

      if (ceo.data.session?.access_token && employee.data.session?.access_token) {
        const apiBase = "http://localhost:5000";
        const ceoToken = ceo.data.session.access_token;
        const employeeToken = employee.data.session.access_token;

        const ceoMe = await api(apiBase, ceoToken, "GET", "/api/me");
        const employeeMe = await api(apiBase, employeeToken, "GET", "/api/me");
        const ceoId = ceoMe.payload?.profile?.id;
        const employeeId = employeeMe.payload?.profile?.id;
        record("CEO GET /api/me", ceoMe.status === 200 && ceoMe.payload?.success === true && Boolean(ceoId));
        record("Employee GET /api/me", employeeMe.status === 200 && employeeMe.payload?.success === true && Boolean(employeeId));
        record("CEO identity has CEO role", ceoMe.payload?.profile?.role === "ceo");
        record("Employee identity is not CEO", Boolean(employeeMe.payload?.profile?.role) && employeeMe.payload.profile.role !== "ceo");

        const ceoList = await api(apiBase, ceoToken, "GET", "/api/profiles");
        const employeeList = await api(apiBase, employeeToken, "GET", "/api/profiles");
        record("CEO GET /api/profiles", ceoList.status === 200 && ceoList.payload?.success === true && Array.isArray(ceoList.payload.profiles));
        record("Employee GET /api/profiles", employeeList.status === 200 && employeeList.payload?.success === true && Array.isArray(employeeList.payload.profiles));
        record("Profile lists omit salary", [ceoList, employeeList].every((result) =>
          Array.isArray(result.payload?.profiles) && result.payload.profiles.every((profile) => !Object.hasOwn(profile, "salary"))));

        const pending = await api(apiBase, ceoToken, "GET", "/api/profiles/pending");
        const employeePending = await api(apiBase, employeeToken, "GET", "/api/profiles/pending");
        record("CEO GET /api/profiles/pending", pending.status === 200 && pending.payload?.success === true && Array.isArray(pending.payload.profiles));
        record("Employee denied pending endpoint", employeePending.status === 403);
        const targetIsPending = Array.isArray(pending.payload?.profiles) &&
          pending.payload.profiles.some((profile) => profile.id === EIMS_TEST_PENDING_PROFILE_ID && profile.status === "pending_approval");
        record("Selected approval target is pending", targetIsPending);

        const allowedUpdate = await api(apiBase, employeeToken, "PATCH", `/api/profiles/${employeeId}`, {
          phone: employeeMe.payload?.profile?.phone ?? null,
        });
        record("Employee authorized personal-field update", allowedUpdate.status === 200 &&
          allowedUpdate.payload?.success === true && Object.hasOwn(allowedUpdate.payload?.profile ?? {}, "phone"));

        const protectedUpdate = await api(apiBase, employeeToken, "PATCH", `/api/profiles/${employeeId}`, { role: "ceo" });
        record("Employee protected-field update rejected", protectedUpdate.status === 400 || protectedUpdate.status === 403);
        const employeeMeAfter = await api(apiBase, employeeToken, "GET", "/api/me");
        record("Protected role unchanged", employeeMeAfter.payload?.profile?.role === employeeMe.payload?.profile?.role);

        const employeeApproval = await api(apiBase, employeeToken, "PATCH", `/api/profiles/${EIMS_TEST_PENDING_PROFILE_ID}/approve`, {});
        record("Non-CEO approval denied", employeeApproval.status === 403);

        if (targetIsPending) {
          const ceoApproval = await api(apiBase, ceoToken, "PATCH", `/api/profiles/${EIMS_TEST_PENDING_PROFILE_ID}/approve`, {});
          record("CEO approval succeeds", ceoApproval.status === 200 && ceoApproval.payload?.success === true &&
            ceoApproval.payload?.profile?.status === "active");
        } else {
          record("CEO approval succeeds", false);
        }

        const ceoMeAfter = await api(apiBase, ceoToken, "GET", "/api/me");
        const employeeMeFinal = await api(apiBase, employeeToken, "GET", "/api/me");
        record("CEO /api/me still works", ceoMeAfter.status === 200 && ceoMeAfter.payload?.success === true);
        record("Employee /api/me still works", employeeMeFinal.status === 200 && employeeMeFinal.payload?.success === true);
      }
    }
  }
} catch {
  record("Smoke-test execution", false);
} finally {
  for (const session of [ceo, employee]) {
    if (session?.data?.session) {
      session.data.session.access_token = "";
      session.data.session.refresh_token = "";
    }
    if (session?.client) await session.client.auth.dispose().catch(() => {});
  }
}

for (const result of results) console.log(`${result.passed ? "PASS" : "FAIL"} ${result.name}`);
const failed = results.some((result) => !result.passed);
process.exitCode = failed ? 1 : 0;
'@

  $jsPath = Join-Path (Get-Location) ".eims-profile-test-$PID.mjs"
  [IO.File]::WriteAllText($jsPath, $js, [Text.UTF8Encoding]::new($false))
  node $jsPath
  $nodeExitCode = $LASTEXITCODE
}
finally {
  if ($jsPath) {
    Remove-Item -LiteralPath $jsPath -Force -ErrorAction SilentlyContinue
  }
  foreach ($name in @(
    "EIMS_TEST_CEO_EMAIL",
    "EIMS_TEST_CEO_PASSWORD",
    "EIMS_TEST_EMPLOYEE_EMAIL",
    "EIMS_TEST_EMPLOYEE_PASSWORD",
    "EIMS_TEST_PENDING_PROFILE_ID"
  )) {
    Remove-Item "Env:$name" -ErrorAction SilentlyContinue
  }
  $ceoEmail = $null
  $ceoPassword = $null
  $employeeEmail = $null
  $employeePassword = $null
  [GC]::Collect()
}

if ($nodeExitCode -ne 0) {
  exit $nodeExitCode
}
