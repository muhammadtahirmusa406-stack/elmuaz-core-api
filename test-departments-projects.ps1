# Local-only integration smoke test for Departments and Projects.
# Uses disposable departments/projects, then removes them in reverse dependency order.
# Requires active CEO, Department Head, and Employee test accounts with the head
# assigned to a department. Credential prompts are masked and values stay local.

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath ".env")) {
  throw "Run this script from the project root, where .env is located."
}

function Read-HiddenValue([string]$Prompt) {
  $secureValue = Read-Host $Prompt -AsSecureString
  $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureValue)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
  finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    $secureValue.Dispose()
  }
}

$ceoEmail = Read-HiddenValue "CEO test-user email (hidden)"
$ceoPassword = Read-HiddenValue "CEO test-user password (hidden)"
$headEmail = Read-HiddenValue "Department Head test-user email (hidden)"
$headPassword = Read-HiddenValue "Department Head test-user password (hidden)"
$employeeEmail = Read-HiddenValue "Employee test-user email (hidden)"
$employeePassword = Read-HiddenValue "Employee test-user password (hidden)"

try {
  $env:EIMS_ORG_CEO_EMAIL = $ceoEmail
  $env:EIMS_ORG_CEO_PASSWORD = $ceoPassword
  $env:EIMS_ORG_HEAD_EMAIL = $headEmail
  $env:EIMS_ORG_HEAD_PASSWORD = $headPassword
  $env:EIMS_ORG_EMPLOYEE_EMAIL = $employeeEmail
  $env:EIMS_ORG_EMPLOYEE_PASSWORD = $employeePassword

  $js = @'
import { config } from "dotenv";
import { createClient } from "@supabase/supabase-js";

const env = {};
config({ path: ".env", quiet: true, processEnv: env });
const { SUPABASE_URL, SUPABASE_ANON_KEY } = env;
const { EIMS_ORG_CEO_EMAIL, EIMS_ORG_CEO_PASSWORD, EIMS_ORG_HEAD_EMAIL,
  EIMS_ORG_HEAD_PASSWORD, EIMS_ORG_EMPLOYEE_EMAIL, EIMS_ORG_EMPLOYEE_PASSWORD } = process.env;
const results = [];
const record = (name, pass) => results.push({ name, pass: Boolean(pass) });
const createdDepartments = [];
const createdProjects = [];
const clients = [];
const base = process.env.EIMS_ORG_API_URL || "http://localhost:5000";

async function signIn(email, password) {
  const client = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  clients.push(client);
  const result = await client.auth.signInWithPassword({ email, password });
  return { client, result };
}

async function api(token, method, path, body) {
  const response = await fetch(`${base}${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      ...(body === undefined ? {} : { "Content-Type": "application/json" }),
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  let payload;
  try { payload = await response.json(); } catch { payload = undefined; }
  return { status: response.status, payload };
}

let ceoToken;
let headToken;
let employeeToken;
try {
  const configOk = Boolean(SUPABASE_URL && SUPABASE_ANON_KEY && EIMS_ORG_CEO_EMAIL &&
    EIMS_ORG_CEO_PASSWORD && EIMS_ORG_HEAD_EMAIL && EIMS_ORG_HEAD_PASSWORD &&
    EIMS_ORG_EMPLOYEE_EMAIL && EIMS_ORG_EMPLOYEE_PASSWORD);
  if (!configOk) {
    record("Local configuration", false);
  } else {
    const [ceo, head, employee] = await Promise.all([
      signIn(EIMS_ORG_CEO_EMAIL, EIMS_ORG_CEO_PASSWORD),
      signIn(EIMS_ORG_HEAD_EMAIL, EIMS_ORG_HEAD_PASSWORD),
      signIn(EIMS_ORG_EMPLOYEE_EMAIL, EIMS_ORG_EMPLOYEE_PASSWORD),
    ]);
    ceoToken = ceo.result.data.session?.access_token;
    headToken = head.result.data.session?.access_token;
    employeeToken = employee.result.data.session?.access_token;
    record("CEO test-user sign-in", !ceo.result.error && Boolean(ceoToken));
    record("Department Head test-user sign-in", !head.result.error && Boolean(headToken));
    record("Employee test-user sign-in", !employee.result.error && Boolean(employeeToken));

    if (ceoToken && headToken && employeeToken) {
      const [ceoMe, headMe, employeeMe] = await Promise.all([
        api(ceoToken, "GET", "/api/me"),
        api(headToken, "GET", "/api/me"),
        api(employeeToken, "GET", "/api/me"),
      ]);
      record("/api/me still works for all roles", [ceoMe, headMe, employeeMe].every((r) => r.status === 200 && r.payload?.success));
      record("Test accounts have expected roles", ceoMe.payload?.profile?.role === "ceo" &&
        headMe.payload?.profile?.role === "department_head" && employeeMe.payload?.profile?.role === "employee");
      const headDepartmentId = headMe.payload?.profile?.department_id;
      record("Department Head has a department assignment", typeof headDepartmentId === "string");

      const [ceoDepartments, headDepartments, employeeDepartments] = await Promise.all([
        api(ceoToken, "GET", "/api/departments"),
        api(headToken, "GET", "/api/departments"),
        api(employeeToken, "GET", "/api/departments"),
      ]);
      record("Authenticated department listing works", [ceoDepartments, headDepartments, employeeDepartments].every((r) => r.status === 200 && Array.isArray(r.payload?.departments)));
      if (headDepartmentId) {
        const headDepartment = await api(headToken, "GET", `/api/departments/${headDepartmentId}`);
        record("Department Head can retrieve assigned department", headDepartment.status === 200);
      } else record("Department Head can retrieve assigned department", false);

      const nonce = Date.now().toString(36).toUpperCase();
      const departmentCreate = await api(ceoToken, "POST", "/api/departments", {
        name: `Smoke Department ${nonce}`,
        code: `SMK${nonce}`,
      });
      const temporaryDepartmentId = departmentCreate.payload?.department?.id;
      if (departmentCreate.status === 201 && temporaryDepartmentId) createdDepartments.push(temporaryDepartmentId);
      record("CEO can create department", departmentCreate.status === 201 && Boolean(temporaryDepartmentId));

      if (temporaryDepartmentId) {
        const getDepartment = await api(ceoToken, "GET", `/api/departments/${temporaryDepartmentId}`);
        const patchDepartment = await api(ceoToken, "PATCH", `/api/departments/${temporaryDepartmentId}`, { name: `Smoke Department Updated ${nonce}` });
        record("CEO can retrieve and update department", getDepartment.status === 200 && patchDepartment.status === 200);
      }

        const headCreateDepartment = await api(headToken, "POST", "/api/departments", { name: "Unauthorized", code: `BAD${nonce}` });
        const employeeCreateDepartment = await api(employeeToken, "POST", "/api/departments", { name: "Unauthorized", code: `BAD2${nonce}` });
        record("Department Head cannot create departments", headCreateDepartment.status === 403);
        record("Employee cannot create departments", employeeCreateDepartment.status === 403);
        if (temporaryDepartmentId) {
          const headChangeOwnership = await api(headToken, "PATCH", `/api/departments/${temporaryDepartmentId}/head`, { head_id: headMe.payload?.profile?.id });
          const headRenameDepartment = await api(headToken, "PATCH", `/api/departments/${temporaryDepartmentId}`, { name: "Unauthorized" });
          record("Department Head cannot assign department ownership", headChangeOwnership.status === 403);
          record("Department Head cannot edit department metadata", headRenameDepartment.status === 403);
        } else {
          record("Department Head cannot assign department ownership", false);
          record("Department Head cannot edit department metadata", false);
        }

      const invalidDepartmentId = await api(ceoToken, "GET", "/api/departments/not-a-uuid");
      const invalidProjectId = await api(ceoToken, "GET", "/api/projects/not-a-uuid");
      record("Invalid department ID rejected", invalidDepartmentId.status === 400);
      record("Invalid project ID rejected", invalidProjectId.status === 400);

      const statusInvalidCreate = await api(ceoToken, "POST", "/api/projects", {
        name: `Invalid status ${nonce}`, department_id: headDepartmentId ?? null, status: "__not_an_existing_status__",
      });
      record("Unknown project status rejected", statusInvalidCreate.status === 400);

      const invalidProgressCreate = await api(ceoToken, "POST", "/api/projects", {
        name: `Invalid progress ${nonce}`, department_id: headDepartmentId ?? null, progress_percent: 101,
      });
      record("Invalid project progress rejected", invalidProgressCreate.status === 400);

      if (headDepartmentId && temporaryDepartmentId) {
        const headProjectCreate = await api(ceoToken, "POST", "/api/projects", {
          name: `Head Department Smoke ${nonce}`, department_id: headDepartmentId,
        });
        const headProjectId = headProjectCreate.payload?.project?.id;
        if (headProjectCreate.status === 201 && headProjectId) createdProjects.push(headProjectId);
        record("CEO can create project in Department Head's department", headProjectCreate.status === 201 && Boolean(headProjectId));

        const otherProjectCreate = await api(ceoToken, "POST", "/api/projects", {
          name: `Cross Department Smoke ${nonce}`, department_id: temporaryDepartmentId,
        });
        const otherProjectId = otherProjectCreate.payload?.project?.id;
        if (otherProjectCreate.status === 201 && otherProjectId) createdProjects.push(otherProjectId);
        record("CEO can create project in another department", otherProjectCreate.status === 201 && Boolean(otherProjectId));
        if (otherProjectId) {
          const ceoProjectRead = await api(ceoToken, "GET", `/api/projects/${otherProjectId}`);
          const ceoProjectUpdate = await api(ceoToken, "PATCH", `/api/projects/${otherProjectId}/progress`, { progress_percent: 65, status: "active" });
          record("CEO can retrieve and update any project", ceoProjectRead.status === 200 && ceoProjectUpdate.status === 200);
        } else record("CEO can retrieve and update any project", false);

        if (headProjectId) {
          const headProjectRead = await api(headToken, "GET", `/api/projects/${headProjectId}`);
          const headProgress = await api(headToken, "PATCH", `/api/projects/${headProjectId}/progress`, { progress_percent: 35 });
          const badProgress = await api(headToken, "PATCH", `/api/projects/${headProjectId}/progress`, { progress_percent: -1 });
          const fractionalProgress = await api(headToken, "PATCH", `/api/projects/${headProjectId}/progress`, { progress_percent: 100.5 });
          record("Department Head can view/manage own project", headProjectRead.status === 200 && headProgress.status === 200);
          record("Invalid progress update rejected", badProgress.status === 400);
          record("Fractional project progress rejected", fractionalProgress.status === 400);
        } else {
          record("Department Head can view/manage own project", false);
          record("Invalid progress update rejected", false);
          record("Fractional project progress rejected", false);
        }

        if (otherProjectId) {
          const crossRead = await api(headToken, "GET", `/api/projects/${otherProjectId}`);
          const crossUpdate = await api(headToken, "PATCH", `/api/projects/${otherProjectId}/progress`, { progress_percent: 20 });
          const crossCreate = await api(headToken, "POST", "/api/projects", {
            name: `Forbidden Cross ${nonce}`, department_id: temporaryDepartmentId,
          });
          record("Cross-department project read blocked", crossRead.status === 404);
          record("Cross-department project update blocked", crossUpdate.status === 404);
          record("Cross-department project creation blocked", crossCreate.status === 403);
        } else {
          record("Cross-department project read blocked", false);
          record("Cross-department project update blocked", false);
          record("Cross-department project creation blocked", false);
        }

        const employeeProjects = await api(employeeToken, "GET", "/api/projects");
        const employeeProjectCreate = await api(employeeToken, "POST", "/api/projects", { name: `Forbidden Employee ${nonce}` });
        const employeeProjectUpdate = headProjectId
          ? await api(employeeToken, "PATCH", `/api/projects/${headProjectId}/progress`, { progress_percent: 99 })
          : { status: 404 };
        record("Employee can view projects", employeeProjects.status === 200 && Array.isArray(employeeProjects.payload?.projects));
        record("Employee cannot list unrelated project", otherProjectId
          ? !employeeProjects.payload?.projects?.some((project) => project.id === otherProjectId)
          : false);
        const employeeCrossProjectRead = otherProjectId
          ? await api(employeeToken, "GET", `/api/projects/${otherProjectId}`)
          : { status: 200 };
        record("Employee cannot read unrelated project by ID", employeeCrossProjectRead.status === 404);
        record("Employee cannot create projects", employeeProjectCreate.status === 403);
        record("Employee cannot update projects", employeeProjectUpdate.status === 403);

        if (headProjectId) {
          const deleteHeadProject = await api(ceoToken, "DELETE", `/api/projects/${headProjectId}`);
          if (deleteHeadProject.status === 200) createdProjects.splice(createdProjects.indexOf(headProjectId), 1);
        }
        if (otherProjectId) {
          const deleteOtherProject = await api(ceoToken, "DELETE", `/api/projects/${otherProjectId}`);
          if (deleteOtherProject.status === 200) createdProjects.splice(createdProjects.indexOf(otherProjectId), 1);
        }
        const deleteDepartment = await api(ceoToken, "DELETE", `/api/departments/${temporaryDepartmentId}`);
        record("CEO can delete unreferenced department", deleteDepartment.status === 200);
        if (deleteDepartment.status === 200) createdDepartments.splice(createdDepartments.indexOf(temporaryDepartmentId), 1);
      } else {
        for (const name of [
          "CEO can create project in Department Head's department",
          "CEO can create project in another department",
          "CEO can retrieve and update any project",
          "Department Head can view/manage own project",
          "Invalid progress update rejected",
          "Fractional project progress rejected",
          "Cross-department project read blocked",
          "Cross-department project update blocked",
          "Cross-department project creation blocked",
          "Employee can view projects",
          "Employee cannot create projects",
          "Employee cannot update projects",
        ]) record(name, false);
      }
    }
  }
} catch {
  record("Smoke-test execution", false);
} finally {
  if (ceoToken) {
    for (const projectId of [...createdProjects].reverse()) {
      const result = await api(ceoToken, "DELETE", `/api/projects/${projectId}`).catch(() => null);
      if (!result || (result.status !== 200 && result.status !== 404)) record("Temporary project cleanup", false);
    }
    for (const departmentId of [...createdDepartments].reverse()) {
      const result = await api(ceoToken, "DELETE", `/api/departments/${departmentId}`).catch(() => null);
      if (!result || (result.status !== 200 && result.status !== 404)) record("Temporary department cleanup", false);
    }
  }
  for (const client of clients) await client.auth.dispose().catch(() => {});
}

for (const result of results) console.log(`${result.pass ? "PASS" : "FAIL"} ${result.name}`);
process.exitCode = results.some((result) => !result.pass) ? 1 : 0;
'@

  $jsPath = Join-Path (Get-Location) ".eims-org-test-$PID.mjs"
  [IO.File]::WriteAllText($jsPath, $js, [Text.UTF8Encoding]::new($false))
  node $jsPath
  $nodeExitCode = $LASTEXITCODE
}
finally {
  if ($jsPath) { Remove-Item -LiteralPath $jsPath -Force -ErrorAction SilentlyContinue }
  foreach ($name in @(
    "EIMS_ORG_CEO_EMAIL", "EIMS_ORG_CEO_PASSWORD", "EIMS_ORG_HEAD_EMAIL",
    "EIMS_ORG_HEAD_PASSWORD", "EIMS_ORG_EMPLOYEE_EMAIL", "EIMS_ORG_EMPLOYEE_PASSWORD"
  )) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
  $ceoEmail = $null
  $ceoPassword = $null
  $headEmail = $null
  $headPassword = $null
  $employeeEmail = $null
  $employeePassword = $null
  [GC]::Collect()
}

if ($nodeExitCode -ne 0) { exit $nodeExitCode }
