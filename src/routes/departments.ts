import { Router } from "express";
import { requireAuth, type AuthenticatedRequest } from "../middleware/auth.js";
import { requireRole } from "../middleware/role.js";
import {
  createDepartment,
  findOtherDepartmentForHead,
  getDepartment,
  getDepartmentHead,
  getProfileForDepartment,
  listDepartments,
  removeDepartment,
  restoreProfileDepartmentRole,
  setDepartmentHeadPointer,
  setProfileDepartmentRole,
  updateDepartment,
} from "../services/departments-service.js";

const router = Router();
const STAFF_ROLES = ["ceo", "department_head", "accountant", "employee"];
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function logDatabaseError(context: string, error: { code?: string }) {
  console.error(context, { code: error.code });
}

function logUnexpectedError(context: string, error: unknown) {
  console.error(context, { name: error instanceof Error ? error.name : "UnknownError" });
}

function validateNameAndCode(body: Record<string, unknown>) {
  const keys = Object.keys(body);
  if (keys.some((key) => key !== "name" && key !== "code")) {
    return { error: "Only name and code are accepted." } as const;
  }

  const changes: Record<string, string> = {};
  for (const key of keys) {
    const value = body[key];
    const maxLength = key === "name" ? 200 : 50;
    if (typeof value !== "string" || value.trim().length === 0 || value.trim().length > maxLength) {
      return { error: `${key} must be a non-empty string of at most ${maxLength} characters.` } as const;
    }
    changes[key] = value.trim();
  }
  if (keys.length === 0) return { error: "Provide at least one department field." } as const;
  return { changes } as const;
}

router.get("/", requireAuth, requireRole(...STAFF_ROLES), async (_req, res) => {
  try {
    const { data, error } = await listDepartments();
    if (error) {
      logDatabaseError("List departments failed", error);
      return res.status(500).json({ success: false, message: "Failed to retrieve departments" });
    }
    return res.json({ success: true, departments: data ?? [] });
  } catch (error) {
    logUnexpectedError("List departments failed", error);
    return res.status(500).json({ success: false, message: "Failed to retrieve departments" });
  }
});

router.get("/:id", requireAuth, requireRole(...STAFF_ROLES), async (req, res) => {
  const departmentId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  if (!UUID_PATTERN.test(departmentId)) {
    return res.status(400).json({ success: false, message: "Department id must be a UUID." });
  }
  try {
    const { data, error } = await getDepartment(departmentId);
    if (error) {
      logDatabaseError("Get department failed", error);
      return res.status(500).json({ success: false, message: "Failed to retrieve department" });
    }
    if (!data) return res.status(404).json({ success: false, message: "Department not found" });
    return res.json({ success: true, department: data });
  } catch (error) {
    logUnexpectedError("Get department failed", error);
    return res.status(500).json({ success: false, message: "Failed to retrieve department" });
  }
});

router.post("/", requireAuth, requireRole("ceo"), async (req, res) => {
  if (!isRecord(req.body)) {
    return res.status(400).json({ success: false, message: "Request body must be a JSON object." });
  }
  const validated = validateNameAndCode(req.body);
  if ("error" in validated) return res.status(400).json({ success: false, message: validated.error });
  if (!("name" in validated.changes) || !("code" in validated.changes)) {
    return res.status(400).json({ success: false, message: "Both name and code are required." });
  }

  try {
    const { data, error } = await createDepartment(validated.changes.name, validated.changes.code);
    if (error) {
      if (error.code === "23505") return res.status(409).json({ success: false, message: "Department name or code already exists." });
      logDatabaseError("Create department failed", error);
      return res.status(500).json({ success: false, message: "Failed to create department" });
    }
    return res.status(201).json({ success: true, department: data });
  } catch (error) {
    logUnexpectedError("Create department failed", error);
    return res.status(500).json({ success: false, message: "Failed to create department" });
  }
});

router.patch("/:id/head", requireAuth, requireRole("ceo"), async (req, res) => {
  const departmentId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  if (!UUID_PATTERN.test(departmentId)) {
    return res.status(400).json({ success: false, message: "Department id must be a UUID." });
  }
  if (!isRecord(req.body) || Object.keys(req.body).length !== 1 || !Object.hasOwn(req.body, "head_id")) {
    return res.status(400).json({ success: false, message: "Provide only head_id as a UUID or null." });
  }
  const requestedHeadId = req.body.head_id;
  if (requestedHeadId !== null && (typeof requestedHeadId !== "string" || !UUID_PATTERN.test(requestedHeadId))) {
    return res.status(400).json({ success: false, message: "head_id must be a UUID or null." });
  }

  try {
    const { data: department, error: departmentError } = await getDepartmentHead(departmentId);
    if (departmentError) {
      logDatabaseError("Read department head failed", departmentError);
      return res.status(500).json({ success: false, message: "Failed to update department head" });
    }
    if (!department) return res.status(404).json({ success: false, message: "Department not found" });

    if (requestedHeadId === null) {
      if (!department.head_id) {
        const { data } = await getDepartment(departmentId);
        return res.json({ success: true, department: data });
      }
      const { data: oldHead, error: oldHeadError } = await getProfileForDepartment(department.head_id);
      if (oldHeadError) {
        logDatabaseError("Read current department head profile failed", oldHeadError);
        return res.status(500).json({ success: false, message: "Failed to update department head" });
      }

      let profileCleared = false;
      if (oldHead?.department_id === departmentId) {
        const { data: clearedProfile, error } = await setProfileDepartmentRole(
          oldHead.id,
          oldHead.role,
          null,
          { role: oldHead.role, status: oldHead.status, department_id: departmentId },
        );
        if (error) {
          logDatabaseError("Clear department head assignment failed", error);
          return res.status(500).json({ success: false, message: "Failed to update department head" });
        }
        if (!clearedProfile) return res.status(409).json({ success: false, message: "Department head assignment changed; refresh and retry." });
        profileCleared = true;
      }

      const { data, error } = await setDepartmentHeadPointer(departmentId, null, department.head_id);
      if (error || !data) {
        if (profileCleared && oldHead) {
          await restoreProfileDepartmentRole(
            oldHead.id,
            oldHead.role,
            departmentId,
            { role: oldHead.role, status: oldHead.status, department_id: null },
          );
        }
        if (!error) return res.status(409).json({ success: false, message: "Department head assignment changed; refresh and retry." });
        logDatabaseError("Clear department head pointer failed", error);
        return res.status(500).json({ success: false, message: "Failed to update department head" });
      }
      return res.json({ success: true, department: data });
    }

    if (department.head_id && department.head_id !== requestedHeadId) {
      return res.status(409).json({ success: false, message: "Remove the current department head before assigning another." });
    }
    const { data: profile, error: profileError } = await getProfileForDepartment(requestedHeadId);
    if (profileError) {
      logDatabaseError("Read proposed department head failed", profileError);
      return res.status(500).json({ success: false, message: "Failed to update department head" });
    }
    if (!profile) return res.status(404).json({ success: false, message: "Profile not found" });
    if (profile.role === "ceo" || profile.status !== "active") {
      return res.status(400).json({ success: false, message: "Department head must be an active non-CEO profile." });
    }
    if (profile.role === "department_head" && profile.department_id && profile.department_id !== departmentId) {
      return res.status(409).json({ success: false, message: "Profile is already assigned as a head of another department." });
    }
    if (profile.department_id && profile.department_id !== departmentId && profile.role === "department_head") {
      return res.status(409).json({ success: false, message: "Unassign the profile from its current department first." });
    }
    const { data: otherDepartment, error: otherDepartmentError } = await findOtherDepartmentForHead(requestedHeadId, departmentId);
    if (otherDepartmentError) {
      logDatabaseError("Check duplicate department head assignment failed", otherDepartmentError);
      return res.status(500).json({ success: false, message: "Failed to update department head" });
    }
    if (otherDepartment) {
      return res.status(409).json({ success: false, message: "Profile is already assigned as another department's head." });
    }

    const { data: updatedProfile, error: profileUpdateError } = await setProfileDepartmentRole(
      requestedHeadId,
      "department_head",
      departmentId,
      { role: profile.role, status: profile.status, department_id: profile.department_id },
    );
    if (profileUpdateError) {
      logDatabaseError("Set department head profile relationship failed", profileUpdateError);
      return res.status(500).json({ success: false, message: "Failed to update department head" });
    }
    if (!updatedProfile) {
      return res.status(409).json({ success: false, message: "Profile assignment changed; refresh and retry." });
    }
    const { data, error } = await setDepartmentHeadPointer(departmentId, requestedHeadId, department.head_id);
    if (error || !data) {
      await restoreProfileDepartmentRole(
        requestedHeadId,
        profile.role,
        profile.department_id,
        { role: "department_head", status: profile.status, department_id: departmentId },
      );
      if (!error) return res.status(409).json({ success: false, message: "Department head assignment changed; refresh and retry." });
      logDatabaseError("Set department head pointer failed", error);
      return res.status(500).json({ success: false, message: "Failed to update department head" });
    }
    return res.json({ success: true, department: data });
  } catch (error) {
    logUnexpectedError("Update department head failed", error);
    return res.status(500).json({ success: false, message: "Failed to update department head" });
  }
});

router.patch("/:id", requireAuth, requireRole("ceo"), async (req, res) => {
  const departmentId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  if (!UUID_PATTERN.test(departmentId)) {
    return res.status(400).json({ success: false, message: "Department id must be a UUID." });
  }
  if (!isRecord(req.body)) {
    return res.status(400).json({ success: false, message: "Request body must be a JSON object." });
  }
  const validated = validateNameAndCode(req.body);
  if ("error" in validated) return res.status(400).json({ success: false, message: validated.error });

  try {
    const { data: existing, error: existingError } = await getDepartment(departmentId);
    if (existingError) {
      logDatabaseError("Read department before update failed", existingError);
      return res.status(500).json({ success: false, message: "Failed to update department" });
    }
    if (!existing) return res.status(404).json({ success: false, message: "Department not found" });
    const { data, error } = await updateDepartment(departmentId, validated.changes);
    if (error) {
      if (error.code === "23505") return res.status(409).json({ success: false, message: "Department name or code already exists." });
      logDatabaseError("Update department failed", error);
      return res.status(500).json({ success: false, message: "Failed to update department" });
    }
    return res.json({ success: true, department: data });
  } catch (error) {
    logUnexpectedError("Update department failed", error);
    return res.status(500).json({ success: false, message: "Failed to update department" });
  }
});

router.delete("/:id", requireAuth, requireRole("ceo"), async (req, res) => {
  const departmentId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  if (!UUID_PATTERN.test(departmentId)) {
    return res.status(400).json({ success: false, message: "Department id must be a UUID." });
  }
  try {
    const { data: existing, error: readError } = await getDepartment(departmentId);
    if (readError) {
      logDatabaseError("Read department before delete failed", readError);
      return res.status(500).json({ success: false, message: "Failed to delete department" });
    }
    if (!existing) return res.status(404).json({ success: false, message: "Department not found" });
    const { data, error } = await removeDepartment(departmentId);
    if (error) {
      if (error.code === "23503") return res.status(409).json({ success: false, message: "Department is assigned to profiles or projects and cannot be deleted." });
      logDatabaseError("Delete department failed", error);
      return res.status(500).json({ success: false, message: "Failed to delete department" });
    }
    if (!data) return res.status(404).json({ success: false, message: "Department not found" });
    return res.json({ success: true, department: { id: data.id } });
  } catch (error) {
    logUnexpectedError("Delete department failed", error);
    return res.status(500).json({ success: false, message: "Failed to delete department" });
  }
});

export default router;
