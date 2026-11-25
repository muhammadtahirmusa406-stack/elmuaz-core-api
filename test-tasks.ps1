# Local-only Task Management smoke test. Requires an active CEO, Department Head,
# and Employee test account in the Department Head's department. It creates one
# clearly labeled task and closes it; the task remains for manual cleanup.
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
$jsPath = Join-Path (Get-Location) ".eims-task-test-$PID.mjs"
$nodeExitCode = 1

try {
  $env:EIMS_TASK_CEO_EMAIL = $ceoEmail
  $env:EIMS_TASK_CEO_PASSWORD = $ceoPassword
  $env:EIMS_TASK_HEAD_EMAIL = $headEmail
  $env:EIMS_TASK_HEAD_PASSWORD = $headPassword
  $env:EIMS_TASK_EMPLOYEE_EMAIL = $employeeEmail
  $env:EIMS_TASK_EMPLOYEE_PASSWORD = $employeePassword

  $js = @'
import { config } from "dotenv";
const localEnv = {};
config({ path: ".env", quiet: true, processEnv: localEnv });

const { SUPABASE_URL, SUPABASE_ANON_KEY } = localEnv;
const base = process.env.EIMS_TASK_API_URL || "http://localhost:5000";
const results = [];
let tokens = {};
let taskId;
const check = (name, pass) => results.push({ name, pass: Boolean(pass) });

async function signIn(email, password) {
  const response = await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=password`, {
    method: "POST",
    headers: { apikey: SUPABASE_ANON_KEY, "Content-Type": "application/json" },
    body: JSON.stringify({ email, password }),
  });
  const payload = await response.json().catch(() => ({}));
  return { ok: response.ok, token: payload.access_token };
}

async function api(token, method, path, body) {
  const response = await fetch(`${base}${path}`, {
    method,
    headers: {
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(body === undefined ? {} : { "Content-Type": "application/json" }),
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  const payload = await response.json().catch(() => ({}));
  return { status: response.status, payload };
}

try {
  check("Local Supabase/API configuration", Boolean(SUPABASE_URL && SUPABASE_ANON_KEY && base));
  if (SUPABASE_URL && SUPABASE_ANON_KEY) {
    const unauth = await api(undefined, "GET", "/api/tasks");
    check("Unauthenticated GET /api/tasks returns 401", unauth.status === 401);
    const unauthComments = await api(undefined, "GET", "/api/tasks/00000000-0000-4000-8000-000000000001/comments");
    check("Unauthenticated task comments return 401", unauthComments.status === 401);

    const signIns = await Promise.all([
      signIn(process.env.EIMS_TASK_CEO_EMAIL, process.env.EIMS_TASK_CEO_PASSWORD),
      signIn(process.env.EIMS_TASK_HEAD_EMAIL, process.env.EIMS_TASK_HEAD_PASSWORD),
      signIn(process.env.EIMS_TASK_EMPLOYEE_EMAIL, process.env.EIMS_TASK_EMPLOYEE_PASSWORD),
    ]);
    tokens = { ceo: signIns[0].token, head: signIns[1].token, employee: signIns[2].token };
    check("CEO test-user sign-in", signIns[0].ok && Boolean(tokens.ceo));
    check("Department Head test-user sign-in", signIns[1].ok && Boolean(tokens.head));
    check("Employee test-user sign-in", signIns[2].ok && Boolean(tokens.employee));

    if (tokens.ceo && tokens.head && tokens.employee) {
      const invalidCommentsId = await api(tokens.ceo, "GET", "/api/tasks/not-a-uuid/comments");
      check("Invalid task ID for comments is rejected", invalidCommentsId.status === 400);
      const [ceoMe, headMe, employeeMe] = await Promise.all([
        api(tokens.ceo, "GET", "/api/me"),
        api(tokens.head, "GET", "/api/me"),
        api(tokens.employee, "GET", "/api/me"),
      ]);
      check("/api/me still works", [ceoMe, headMe, employeeMe].every((r) => r.status === 200 && r.payload?.success));
      const headProfile = headMe.payload?.profile;
      const employeeProfile = employeeMe.payload?.profile;
      check("Test users have expected roles and a shared department",
        ceoMe.payload?.profile?.role === "ceo" && headProfile?.role === "department_head" &&
        employeeProfile?.role === "employee" && Boolean(headProfile?.department_id) &&
        headProfile.department_id === employeeProfile.department_id);

      const [employeeTasks, employeeCreate, headTasks, headCreate] = await Promise.all([
        api(tokens.employee, "GET", "/api/tasks"),
        api(tokens.employee, "POST", "/api/tasks", { title: "Unauthorized employee task", assigned_to: employeeProfile?.id }),
        api(tokens.head, "GET", "/api/tasks"),
        api(tokens.head, "POST", "/api/tasks", { title: "Missing assignment test" }),
      ]);
      check("Employee can list authorized tasks", employeeTasks.status === 200 && Array.isArray(employeeTasks.payload?.tasks));
      check("Employee cannot create tasks", employeeCreate.status === 403);
      check("Department Head can list authorized tasks", headTasks.status === 200 && Array.isArray(headTasks.payload?.tasks));
      check("Invalid Department Head task creation is rejected", headCreate.status === 400);

      const projectsResult = await api(tokens.ceo, "GET", "/api/projects");
      const allProjects = projectsResult.payload?.projects ?? [];
      const project = allProjects.find((item) => item.department_id === headProfile?.department_id);
      const otherDepartmentProject = allProjects.find((item) => item.department_id && item.department_id !== headProfile?.department_id);
      check("An existing project is available in the test department", Boolean(project?.id));
      if (otherDepartmentProject?.id && employeeProfile?.id) {
        const crossDepartmentCreate = await api(tokens.head, "POST", "/api/tasks", {
          title: `Cross-department rejection ${Date.now().toString(36)}`,
          assigned_to: employeeProfile.id,
          project_id: otherDepartmentProject.id,
        });
        check("Department Head cannot create tasks in another department", crossDepartmentCreate.status === 403);
      } else check("Department Head cannot create tasks in another department", false);

      const nonce = Date.now().toString(36).toUpperCase();
      if (projectsResult.status === 200 && project?.id && employeeProfile?.id) {
        const created = await api(tokens.ceo, "POST", "/api/tasks", {
          title: `[LOCAL TASK SMOKE] ${nonce}`,
          description: "Created by test-tasks.ps1; close after workflow verification.",
          assigned_to: employeeProfile.id,
          project_id: project.id,
          priority: "low",
          stage: "assigned",
        });
        taskId = created.payload?.task?.id;
        check("CEO can create a task for an active employee", created.status === 201 && Boolean(taskId));

        if (taskId) {
          const employeeList = await api(tokens.employee, "GET", "/api/tasks");
          check("Assignee can see the created task", employeeList.status === 200 && employeeList.payload?.tasks?.some((item) => item.id === taskId));

          const emptyComment = await api(tokens.employee, "POST", `/api/tasks/${taskId}/comments`, { comment: "   " });
          const forgedAuthorComment = await api(tokens.employee, "POST", `/api/tasks/${taskId}/comments`, {
            comment: "Should reject caller-supplied author", author_id: ceoMe.payload?.profile?.id,
          });
          const addedComment = await api(tokens.employee, "POST", `/api/tasks/${taskId}/comments`, { comment: "Local comments smoke test" });
          const listedComments = await api(tokens.employee, "GET", `/api/tasks/${taskId}/comments`);
          check("Empty task comment is rejected", emptyComment.status === 400);
          check("Caller-supplied comment author is rejected", forgedAuthorComment.status === 400);
          check("Authorized user can create and read task comments",
            addedComment.status === 201 && addedComment.payload?.comment?.author_id === employeeProfile.id &&
            listedComments.status === 200 && listedComments.payload?.comments?.some((item) => item.id === addedComment.payload?.comment?.id));

          const selfReview = await api(tokens.employee, "POST", `/api/tasks/${taskId}/review`, { decision: "approved" });
          check("Employee cannot approve own task", selfReview.status === 403);

          const invalidJump = await api(tokens.employee, "PATCH", `/api/tasks/${taskId}/stage`, { stage: "approved" });
          check("Invalid stage jump is rejected", invalidJump.status === 400);

          const start = await api(tokens.employee, "PATCH", `/api/tasks/${taskId}/stage`, { stage: "in_progress" });
          check("Assignee can start assigned task", start.status === 200);

          const unauthorizedAssignment = await api(tokens.head, "POST", "/api/tasks", {
            title: `Unauthorized assignment ${nonce}`, assigned_to: employeeProfile.id,
          });
          check("Department Head cannot create task without an authorized project", unauthorizedAssignment.status === 403);

          const submission = await api(tokens.employee, "POST", `/api/tasks/${taskId}/submissions`, { content: "Local smoke test submission" });
          check("Assignee can submit work", submission.status === 201);
          const enterReview = await api(tokens.head, "PATCH", `/api/tasks/${taskId}/stage`, { stage: "under_review" });
          check("Department Head can review a task in their project", enterReview.status === 200);
          const correct = await api(tokens.head, "POST", `/api/tasks/${taskId}/review`, { decision: "needs_correction", review_comment: "Smoke test correction" });
          check("Authorized review can request correction", correct.status === 200 && correct.payload?.task?.stage === "needs_correction");

          const resume = await api(tokens.employee, "PATCH", `/api/tasks/${taskId}/stage`, { stage: "in_progress" });
          const resubmit = await api(tokens.employee, "POST", `/api/tasks/${taskId}/submissions`, { content: "Local smoke test resubmission" });
          const reenterReview = await api(tokens.head, "PATCH", `/api/tasks/${taskId}/stage`, { stage: "under_review" });
          const approve = await api(tokens.head, "POST", `/api/tasks/${taskId}/review`, { decision: "approved", review_comment: "Smoke test approval" });
          check("needs_correction flow can return to approved", resume.status === 200 && resubmit.status === 201 &&
            reenterReview.status === 200 && approve.status === 200 && approve.payload?.task?.stage === "approved");

          const employeeClose = await api(tokens.employee, "PATCH", `/api/tasks/${taskId}/stage`, { stage: "closed" });
          check("Assignee cannot close approved task", employeeClose.status === 400);
          const close = await api(tokens.ceo, "PATCH", `/api/tasks/${taskId}/stage`, { stage: "closed" });
          check("CEO can close approved task", close.status === 200 && close.payload?.task?.stage === "closed");
        }
      } else {
        for (const name of [
          "CEO can create a task for an active employee", "Assignee can see the created task",
          "Empty task comment is rejected", "Caller-supplied comment author is rejected",
          "Authorized user can create and read task comments",
          "Employee cannot approve own task", "Invalid stage jump is rejected", "Assignee can start assigned task",
          "Department Head cannot create task without an authorized project", "Assignee can submit work",
          "Department Head can review a task in their project", "Authorized review can request correction",
          "needs_correction flow can return to approved", "Assignee cannot close approved task", "CEO can close approved task",
        ]) check(name, false);
      }

      const invalidId = await api(tokens.ceo, "PATCH", "/api/tasks/not-a-uuid/stage", { stage: "assigned" });
      check("Invalid task ID is rejected", invalidId.status === 400);
      check("Profiles endpoint remains available", (await api(tokens.ceo, "GET", "/api/profiles")).status === 200);
      check("Departments endpoint remains available", (await api(tokens.ceo, "GET", "/api/departments")).status === 200);
      check("Projects endpoint remains available", projectsResult.status === 200);
    }
  }
} catch {
  check("Smoke-test execution", false);
} finally {
  for (const key of [
    "EIMS_TASK_CEO_EMAIL", "EIMS_TASK_CEO_PASSWORD", "EIMS_TASK_HEAD_EMAIL",
    "EIMS_TASK_HEAD_PASSWORD", "EIMS_TASK_EMPLOYEE_EMAIL", "EIMS_TASK_EMPLOYEE_PASSWORD",
  ]) process.env[key] = "";
  tokens = {};
  if (taskId) console.log("INFO Created one [LOCAL TASK SMOKE] task; it is closed and remains for manual cleanup.");
}

for (const result of results) console.log(`${result.pass ? "PASS" : "FAIL"} ${result.name}`);
process.exitCode = results.some((result) => !result.pass) ? 1 : 0;
'@
  [IO.File]::WriteAllText($jsPath, $js, [Text.UTF8Encoding]::new($false))
  node $jsPath
  $nodeExitCode = $LASTEXITCODE
}
finally {
  if (Test-Path -LiteralPath $jsPath) { Remove-Item -LiteralPath $jsPath -Force -ErrorAction SilentlyContinue }
  foreach ($name in @(
    "EIMS_TASK_CEO_EMAIL", "EIMS_TASK_CEO_PASSWORD", "EIMS_TASK_HEAD_EMAIL",
    "EIMS_TASK_HEAD_PASSWORD", "EIMS_TASK_EMPLOYEE_EMAIL", "EIMS_TASK_EMPLOYEE_PASSWORD"
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
