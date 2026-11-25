import { Router, type Response } from "express";
import { requireAuth, type AuthenticatedRequest } from "../middleware/auth.js";
import { requireRole } from "../middleware/role.js";
import {
  createProject,
  deleteProject,
  departmentExists,
  getProject,
  getProjectActor,
  getProjectLead,
  listKnownProjectStatuses,
  listProjects,
  listProjectsForProfile,
  profileHasProjectTask,
  updateProject,
} from "../services/projects-service.js";

const router = Router();
const STAFF_ROLES = ["ceo", "department_head", "accountant", "employee"];
const PROJECT_MANAGER_ROLES = ["ceo", "department_head"];
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const PROJECT_UPDATE_FIELDS = new Set([
  "name",
  "department_id",
  "description",
  "progress_percent",
  "status",
  "lead_id",
]);

type ProjectActor = {
  id: string;
  role: string;
  status: string;
  department_id: string | null;
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function logDatabaseError(context: string, error: { code?: string }) {
  console.error(context, { code: error.code });
}

function logUnexpectedError(context: string, error: unknown) {
  console.error(context, { name: error instanceof Error ? error.name : "UnknownError" });
}

function validateProjectFields(body: Record<string, unknown>, creating: boolean) {
  const values: Record<string, unknown> = {};
  for (const [field, value] of Object.entries(body)) {
    if (!PROJECT_UPDATE_FIELDS.has(field)) {
      return { error: "One or more project fields are not allowed." } as const;
    }

    if (field === "name") {
      if (typeof value !== "string" || value.trim().length < 1 || value.trim().length > 200) {
        return { error: "name must be a non-empty string of at most 200 characters." } as const;
      }
      values.name = value.trim();
    } else if (field === "description") {
      if (value !== null && typeof value !== "string") {
        return { error: "description must be a string or null." } as const;
      }
      values.description = typeof value === "string" ? value.trim() || null : null;
    } else if (field === "department_id" || field === "lead_id") {
      if (value !== null && (typeof value !== "string" || !UUID_PATTERN.test(value))) {
        return { error: `${field} must be a UUID or null.` } as const;
      }
      values[field] = value;
    } else if (field === "progress_percent") {
      if (typeof value !== "number" || !Number.isInteger(value) || value < 0 || value > 100) {
        return { error: "progress_percent must be an integer from 0 through 100." } as const;
      }
      values.progress_percent = value;
    } else if (field === "status") {
      if (typeof value !== "string" || value.trim().length < 1 || value.trim().length > 100) {
        return { error: "status must be a non-empty string of at most 100 characters." } as const;
      }
      values.status = value.trim();
    }
  }

  if (creating && (typeof values.name !== "string" || Object.keys(values).length === 0)) {
    return { error: "name is required." } as const;
  }
  if (!creating && Object.keys(values).length === 0) {
    return { error: "Provide at least one project field." } as const;
  }
  return { values } as const;
}

async function loadActor(req: AuthenticatedRequest, res: Response): Promise<ProjectActor | null> {
  const { data: actor, error } = await getProjectActor(req.user.id);
  if (error) {
    logDatabaseError("Read project actor failed", error);
    res.status(500).json({ success: false, message: "Failed to authorize project operation" });
    return null;
  }
  if (!actor || actor.status !== "active" || !STAFF_ROLES.includes(actor.role)) {
    res.status(403).json({ success: false, message: "You do not have permission to access projects." });
    return null;
  }
  return actor;
}

async function validateKnownStatus(status: unknown, res: Response): Promise<boolean> {
  if (status === undefined) return true;
  const { data, error } = await listKnownProjectStatuses();
  if (error) {
    logDatabaseError("Read existing project statuses failed", error);
    res.status(500).json({ success: false, message: "Failed to validate project status" });
    return false;
  }
  // The schema stores status as unconstrained text. Accept only values already
  // used in the table plus its declared default; do not invent a status enum.
  const knownStatuses = new Set(["active", ...(data ?? []).map((row) => row.status)]);
  if (typeof status !== "string" || !knownStatuses.has(status)) {
    res.status(400).json({ success: false, message: "status must match an existing project status." });
    return false;
  }
  return true;
}

async function validateDepartmentAndLead(
  departmentId: unknown,
  leadId: unknown,
  res: Response,
): Promise<boolean> {
  if (departmentId !== null && departmentId !== undefined) {
    if (typeof departmentId !== "string" || !UUID_PATTERN.test(departmentId)) {
      res.status(400).json({ success: false, message: "department_id must be a UUID or null." });
      return false;
    }
    const { data: department, error } = await departmentExists(departmentId);
    if (error) {
      logDatabaseError("Validate project department failed", error);
      res.status(500).json({ success: false, message: "Failed to validate project department" });
      return false;
    }
    if (!department) {
      res.status(400).json({ success: false, message: "department_id does not identify an existing department." });
      return false;
    }
  }

  if (leadId !== null && leadId !== undefined) {
    if (typeof leadId !== "string" || !UUID_PATTERN.test(leadId)) {
      res.status(400).json({ success: false, message: "lead_id must be a UUID or null." });
      return false;
    }
    if (typeof departmentId !== "string") {
      res.status(400).json({ success: false, message: "A project lead requires a department assignment." });
      return false;
    }
    const { data: lead, error } = await getProjectLead(leadId);
    if (error) {
      logDatabaseError("Validate project lead failed", error);
      res.status(500).json({ success: false, message: "Failed to validate project lead" });
      return false;
    }
    if (!lead || lead.status !== "active" || lead.department_id !== departmentId) {
      res.status(400).json({ success: false, message: "Project lead must be an active profile in the project's department." });
      return false;
    }
  }
  return true;
}

router.get("/", requireAuth, requireRole(...STAFF_ROLES), async (req, res) => {
  try {
    const actor = await loadActor(req as AuthenticatedRequest, res);
    if (!actor) return;
    if (actor.role === "department_head" && !actor.department_id) {
      return res.json({ success: true, projects: [] });
    }
    const result = actor.role === "ceo"
      ? await listProjects()
      : actor.role === "department_head"
        ? await listProjects(actor.department_id ?? undefined)
        : await listProjectsForProfile(actor.id);
    const { data, error } = result;
    if (error) {
      logDatabaseError("List projects failed", error);
      return res.status(500).json({ success: false, message: "Failed to retrieve projects" });
    }
    return res.json({ success: true, projects: data ?? [] });
  } catch (error) {
    logUnexpectedError("List projects failed", error);
    return res.status(500).json({ success: false, message: "Failed to retrieve projects" });
  }
});

router.get("/:id", requireAuth, requireRole(...STAFF_ROLES), async (req, res) => {
  const projectId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  if (!UUID_PATTERN.test(projectId)) {
    return res.status(400).json({ success: false, message: "Project id must be a UUID." });
  }
  try {
    const actor = await loadActor(req as AuthenticatedRequest, res);
    if (!actor) return;
    const { data: project, error } = await getProject(projectId);
    if (error) {
      logDatabaseError("Get project failed", error);
      return res.status(500).json({ success: false, message: "Failed to retrieve project" });
    }
    let hasAccess = Boolean(project);
    if (project && actor.role === "department_head") {
      hasAccess = Boolean(actor.department_id) && project.department_id === actor.department_id;
    }
    if (project && (actor.role === "employee" || actor.role === "accountant") && project.lead_id !== actor.id) {
      const { data: taskAccess, error: taskAccessError } = await profileHasProjectTask(actor.id, projectId);
      if (taskAccessError) {
        logDatabaseError("Check profile project access failed", taskAccessError);
        return res.status(500).json({ success: false, message: "Failed to retrieve project" });
      }
      hasAccess = Boolean(taskAccess);
    }
    if (!project || !hasAccess) {
      return res.status(404).json({ success: false, message: "Project not found" });
    }
    return res.json({ success: true, project });
  } catch (error) {
    logUnexpectedError("Get project failed", error);
    return res.status(500).json({ success: false, message: "Failed to retrieve project" });
  }
});

router.post("/", requireAuth, requireRole(...PROJECT_MANAGER_ROLES), async (req, res) => {
  if (!isRecord(req.body)) {
    return res.status(400).json({ success: false, message: "Request body must be a JSON object." });
  }
  const validated = validateProjectFields(req.body, true);
  if ("error" in validated) return res.status(400).json({ success: false, message: validated.error });

  try {
    const actor = await loadActor(req as AuthenticatedRequest, res);
    if (!actor) return;
    const values = validated.values;
    if (actor.role === "department_head") {
      if (!actor.department_id) return res.status(403).json({ success: false, message: "Department head has no assigned department." });
      if (values.department_id !== undefined && values.department_id !== actor.department_id) {
        return res.status(403).json({ success: false, message: "You may create projects only in your own department." });
      }
      values.department_id = actor.department_id;
    }
    if (values.department_id === undefined) values.department_id = null;
    if (values.progress_percent === undefined) values.progress_percent = 0;
    if (values.status === undefined) values.status = "active";
    if (!(await validateKnownStatus(values.status, res))) return;
    if (!(await validateDepartmentAndLead(values.department_id, values.lead_id, res))) return;

    const { data, error } = await createProject(values);
    if (error) {
      logDatabaseError("Create project failed", error);
      return res.status(500).json({ success: false, message: "Failed to create project" });
    }
    return res.status(201).json({ success: true, project: data });
  } catch (error) {
    logUnexpectedError("Create project failed", error);
    return res.status(500).json({ success: false, message: "Failed to create project" });
  }
});

async function updateProjectRoute(req: AuthenticatedRequest, res: Response, progressOnly: boolean) {
  const projectId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  if (!UUID_PATTERN.test(projectId)) {
    return res.status(400).json({ success: false, message: "Project id must be a UUID." });
  }
  if (!isRecord(req.body)) {
    return res.status(400).json({ success: false, message: "Request body must be a JSON object." });
  }
  if (progressOnly && Object.keys(req.body).some((field) => field !== "progress_percent" && field !== "status")) {
    return res.status(400).json({ success: false, message: "Progress endpoint accepts only progress_percent and status." });
  }
  const validated = validateProjectFields(req.body, false);
  if ("error" in validated) return res.status(400).json({ success: false, message: validated.error });

  try {
    const actor = await loadActor(req, res);
    if (!actor) return;
    const { data: current, error: readError } = await getProject(projectId);
    if (readError) {
      logDatabaseError("Read project before update failed", readError);
      return res.status(500).json({ success: false, message: "Failed to update project" });
    }
    if (!current || (actor.role === "department_head" && current.department_id !== actor.department_id)) {
      return res.status(404).json({ success: false, message: "Project not found" });
    }

    const values = validated.values;
    if (actor.role === "department_head" && Object.hasOwn(values, "department_id")) {
      return res.status(403).json({ success: false, message: "Department heads cannot reassign project departments." });
    }
    const targetDepartmentId = Object.hasOwn(values, "department_id")
      ? values.department_id
      : current.department_id;
    if (actor.role === "department_head" && targetDepartmentId !== actor.department_id) {
      return res.status(403).json({ success: false, message: "You may manage projects only in your own department." });
    }
    if (Object.hasOwn(values, "status") && !(await validateKnownStatus(values.status, res))) return;

    const leadChanged = Object.hasOwn(values, "lead_id");
    const departmentChanged = Object.hasOwn(values, "department_id");
    if (leadChanged || departmentChanged) {
      const targetLeadId = leadChanged ? values.lead_id : current.lead_id;
      if (!(await validateDepartmentAndLead(targetDepartmentId, targetLeadId, res))) return;
    }

    const { data, error } = await updateProject(projectId, values);
    if (error) {
      logDatabaseError("Update project failed", error);
      return res.status(500).json({ success: false, message: "Failed to update project" });
    }
    if (!data) return res.status(404).json({ success: false, message: "Project not found" });
    return res.json({ success: true, project: data });
  } catch (error) {
    logUnexpectedError("Update project failed", error);
    return res.status(500).json({ success: false, message: "Failed to update project" });
  }
}

router.patch("/:id/progress", requireAuth, requireRole(...PROJECT_MANAGER_ROLES), (req, res) =>
  updateProjectRoute(req as AuthenticatedRequest, res, true));

router.patch("/:id", requireAuth, requireRole(...PROJECT_MANAGER_ROLES), (req, res) =>
  updateProjectRoute(req as AuthenticatedRequest, res, false));

router.delete("/:id", requireAuth, requireRole("ceo"), async (req, res) => {
  const projectId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  if (!UUID_PATTERN.test(projectId)) {
    return res.status(400).json({ success: false, message: "Project id must be a UUID." });
  }
  try {
    const { data: existing, error: readError } = await getProject(projectId);
    if (readError) {
      logDatabaseError("Read project before delete failed", readError);
      return res.status(500).json({ success: false, message: "Failed to delete project" });
    }
    if (!existing) return res.status(404).json({ success: false, message: "Project not found" });
    const { data, error } = await deleteProject(projectId);
    if (error) {
      if (error.code === "23503") return res.status(409).json({ success: false, message: "Project is referenced by tasks and cannot be deleted." });
      logDatabaseError("Delete project failed", error);
      return res.status(500).json({ success: false, message: "Failed to delete project" });
    }
    if (!data) return res.status(404).json({ success: false, message: "Project not found" });
    return res.json({ success: true, project: { id: data.id } });
  } catch (error) {
    logUnexpectedError("Delete project failed", error);
    return res.status(500).json({ success: false, message: "Failed to delete project" });
  }
});

export default router;
