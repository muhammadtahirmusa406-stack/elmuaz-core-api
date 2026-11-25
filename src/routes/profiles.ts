import { Router } from "express";
import {
  requireAuth,
  type AuthenticatedRequest,
} from "../middleware/auth.js";
import { requireRole } from "../middleware/role.js";
import {
  approvePendingProfile,
  CEO_EDITABLE_FIELDS,
  createPendingEmployeeProfile,
  findAuthUser,
  getProfileById,
  listProfiles,
  listPendingProfiles,
  profileAlreadyExists,
  rejectPendingProfile,
  SAFE_PROFILE_FIELDS,
  SELF_EDITABLE_FIELDS,
  updateProfile,
} from "../services/profile-service.js";
import { createUserSupabaseClient } from "../config/supabase-user.js";
import { recordActivityLog } from "../services/activity-log-service.js";

const router = Router();
const STAFF_ROLES = ["ceo", "department_head", "accountant", "employee"];
const VALID_ROLES = ["employee", "department_head", "accountant"];
const VALID_STATUSES = ["active", "suspended", "inactive", "probation", "on_leave", "terminated"];
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function logDatabaseError(context: string, error: { code?: string; message?: string }) {
  console.error(context, {
    code: error.code,
  });
}

function logUnexpectedError(context: string, error: unknown) {
  console.error(context, {
    name: error instanceof Error ? error.name : "UnknownError",
  });
}

function safeProfileResponse(profile: Record<string, unknown>) {
  const fields = SAFE_PROFILE_FIELDS.split(", ");
  return Object.fromEntries(fields.map((field) => [field, profile[field]]));
}

function validatePersonalChanges(body: Record<string, unknown>) {
  const changes: Record<string, unknown> = {};
  const allowed = new Set<string>([...SELF_EDITABLE_FIELDS, ...CEO_EDITABLE_FIELDS]);

  for (const [field, value] of Object.entries(body)) {
    if (!allowed.has(field)) {
      return { error: "One or more fields are not allowed." } as const;
    }

    if (field === "full_name") {
      if (typeof value !== "string" || value.trim().length < 1 || value.trim().length > 200) {
        return { error: "full_name must be a non-empty string of at most 200 characters." } as const;
      }
      changes[field] = value.trim();
      continue;
    }

    if (field === "phone" || field === "job_title" || field === "avatar_url") {
      const maxLength = field === "phone" ? 40 : field === "job_title" ? 150 : 2048;
      if (value !== null && (typeof value !== "string" || value.length > maxLength)) {
        return { error: `${field} must be a string of at most ${maxLength} characters or null.` } as const;
      }
      changes[field] = typeof value === "string" ? value.trim() || null : value;
      continue;
    }

    if (field === "role") {
      if (typeof value !== "string" || !VALID_ROLES.includes(value)) {
        return { error: "role must be employee, department_head, or accountant." } as const;
      }
      changes[field] = value;
      continue;
    }

    if (field === "status") {
      if (typeof value !== "string" || !VALID_STATUSES.includes(value)) {
        return { error: "status is invalid; use the approval endpoint for pending profiles." } as const;
      }
      changes[field] = value;
      continue;
    }

    if (field === "salary") {
      if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || value > 9999999999999.99) {
        return { error: "salary must be a non-negative number within the supported range." } as const;
      }
      changes[field] = value;
      continue;
    }

    if (field === "department_id") {
      if (value !== null && (typeof value !== "string" || !UUID_PATTERN.test(value))) {
        return { error: "department_id must be a UUID or null." } as const;
      }
      changes[field] = value;
    }
  }

  if (Object.keys(changes).length === 0) {
    return { error: "Provide at least one allowed profile field." } as const;
  }

  return { changes } as const;
}

router.get("/me", requireAuth, async (req, res) => {
  try {
    const authenticatedRequest = req as AuthenticatedRequest;
    const userSupabase = createUserSupabaseClient(authenticatedRequest.accessToken);
    const { data: profile, error } = await userSupabase
      .from("profiles")
      .select(
        "id, full_name, email, phone, role, job_title, avatar_url, status, department_id, auth_provider, approved_by, approved_at, created_at, updated_at",
      )
      .eq("id", authenticatedRequest.user.id)
      .single();

    if (error || !profile) {
      if (error) logDatabaseError("Get current profile failed", error);
      return res.status(404).json({ success: false, message: "Profile not found" });
    }

    return res.json({ success: true, profile });
  } catch (error) {
    logUnexpectedError("Get current profile failed", error);
    return res.status(500).json({ success: false, message: "Failed to retrieve profile" });
  }
});

router.get(
  "/profiles",
  requireAuth,
  requireRole(...STAFF_ROLES),
  async (req, res) => {
    try {
      const authenticatedRequest = req as AuthenticatedRequest;
      const callerSupabase = createUserSupabaseClient(authenticatedRequest.accessToken);
      const { data: caller, error: callerError } = await callerSupabase
        .from("profiles")
        .select("role")
        .eq("id", authenticatedRequest.user.id)
        .single();
      if (callerError || !caller) {
        if (callerError) logDatabaseError("Read caller role for profile list failed", callerError);
        return res.status(403).json({ success: false, message: "User profile not found" });
      }

      const { data, error } = await listProfiles(caller.role === "ceo");
      if (error) {
        logDatabaseError("List profiles failed", error);
        return res.status(500).json({ success: false, message: "Failed to retrieve profiles" });
      }
      return res.json({ success: true, profiles: data ?? [] });
    } catch (error) {
      logUnexpectedError("List profiles failed", error);
      return res.status(500).json({ success: false, message: "Failed to retrieve profiles" });
    }
  },
);

router.get(
  "/profiles/pending",
  requireAuth,
  requireRole("ceo"),
  async (_req, res) => {
    try {
      const { data, error } = await listPendingProfiles();
      if (error) {
        logDatabaseError("List pending profiles failed", error);
        return res.status(500).json({ success: false, message: "Failed to retrieve pending profiles" });
      }
      return res.json({ success: true, profiles: data ?? [] });
    } catch (error) {
      logUnexpectedError("List pending profiles failed", error);
      return res.status(500).json({ success: false, message: "Failed to retrieve pending profiles" });
    }
  },
);

router.patch(
  "/profiles/:id/approve",
  requireAuth,
  requireRole("ceo"),
  async (req, res) => {
    const profileId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
    if (!UUID_PATTERN.test(profileId)) {
      return res.status(400).json({ success: false, message: "Profile id must be a UUID." });
    }
    if (req.body !== undefined && (!isRecord(req.body) || Object.keys(req.body).length !== 0)) {
      return res.status(400).json({ success: false, message: "Profile approval does not accept request fields." });
    }

    try {
      const current = await getProfileById(profileId);
      if (current.error) {
        logDatabaseError("Read profile for approval failed", current.error);
        return res.status(500).json({ success: false, message: "Failed to approve profile" });
      }
      if (!current.data) {
        return res.status(404).json({ success: false, message: "Profile not found" });
      }
      if (current.data.status !== "pending_approval") {
        return res.status(409).json({ success: false, message: "Profile is not pending approval" });
      }

      const authenticatedRequest = req as AuthenticatedRequest;
      const { data: profile, error } = await approvePendingProfile(
        profileId,
        authenticatedRequest.user.id,
        new Date().toISOString(),
      );
      if (error) {
        logDatabaseError("Approve profile failed", error);
        return res.status(500).json({ success: false, message: "Failed to approve profile" });
      }
      if (!profile) {
        return res.status(409).json({ success: false, message: "Profile is no longer pending approval" });
      }
      return res.json({ success: true, profile });
    } catch (error) {
      logUnexpectedError("Approve profile failed", error);
      return res.status(500).json({ success: false, message: "Failed to approve profile" });
    }
  },
);

router.patch(
  "/profiles/:id/reject",
  requireAuth,
  requireRole("ceo"),
  async (req, res) => {
    const profileId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
    if (!UUID_PATTERN.test(profileId)) {
      return res.status(400).json({ success: false, message: "Profile id must be a UUID." });
    }
    if (req.body !== undefined && (!isRecord(req.body) || Object.keys(req.body).length !== 0)) {
      return res.status(400).json({ success: false, message: "Profile rejection does not accept request fields." });
    }

    try {
      const current = await getProfileById(profileId);
      if (current.error) {
        logDatabaseError("Read profile for rejection failed", current.error);
        return res.status(500).json({ success: false, message: "Failed to reject profile" });
      }
      if (!current.data) {
        return res.status(404).json({ success: false, message: "Profile not found" });
      }
      if (current.data.status !== "pending_approval") {
        return res.status(409).json({ success: false, message: "Profile is not pending approval" });
      }

      const authenticatedRequest = req as AuthenticatedRequest;
      const { data: profile, error } = await rejectPendingProfile(
        profileId,
        authenticatedRequest.user.id,
      );
      if (error) {
        logDatabaseError("Reject profile failed", error);
        return res.status(500).json({ success: false, message: "Failed to reject profile" });
      }
      if (!profile) {
        return res.status(409).json({ success: false, message: "Profile is no longer pending approval" });
      }

      await recordActivityLog({
        actorId: authenticatedRequest.user.id,
        action: "employee_profile.rejected",
        entityType: "employee_profile",
        entityId: profileId,
      });
      return res.json({ success: true, profile });
    } catch (error) {
      logUnexpectedError("Reject profile failed", error);
      return res.status(500).json({ success: false, message: "Failed to reject profile" });
    }
  },
);

router.patch(
  "/profiles/:id",
  requireAuth,
  requireRole(...STAFF_ROLES),
  async (req, res) => {
    const profileId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
    if (!UUID_PATTERN.test(profileId)) {
      return res.status(400).json({ success: false, message: "Profile id must be a UUID." });
    }
    if (!isRecord(req.body)) {
      return res.status(400).json({ success: false, message: "Request body must be a JSON object." });
    }

    const validated = validatePersonalChanges(req.body);
    if ("error" in validated) {
      return res.status(400).json({ success: false, message: validated.error });
    }

    const authenticatedRequest = req as AuthenticatedRequest;
    try {
      const callerSupabase = createUserSupabaseClient(authenticatedRequest.accessToken);
      const { data: caller, error: callerError } = await callerSupabase
        .from("profiles")
        .select("role")
        .eq("id", authenticatedRequest.user.id)
        .single();
      if (callerError || !caller) {
        if (callerError) logDatabaseError("Read caller profile failed", callerError);
        return res.status(403).json({ success: false, message: "User profile not found" });
      }
      const callerIsCeo = caller.role === "ceo";
      if (!callerIsCeo && profileId !== authenticatedRequest.user.id) {
        return res.status(403).json({ success: false, message: "You may only update your own profile." });
      }

      const hasAdminChanges = Object.keys(validated.changes).some((field) =>
        (CEO_EDITABLE_FIELDS as readonly string[]).includes(field),
      );
      if (hasAdminChanges && !callerIsCeo) {
        return res.status(403).json({ success: false, message: "Administrative profile fields are CEO-only." });
      }
      if (hasAdminChanges && profileId === authenticatedRequest.user.id) {
        return res.status(403).json({ success: false, message: "CEO administrative fields cannot be changed on the CEO's own profile." });
      }

      const current = await getProfileById(profileId);
      if (current.error) {
        logDatabaseError("Read profile before update failed", current.error);
        return res.status(500).json({ success: false, message: "Failed to update profile" });
      }
      if (!current.data) {
        return res.status(404).json({ success: false, message: "Profile not found" });
      }
      if (validated.changes.role === "department_head" && current.data.role !== "department_head") {
        return res.status(400).json({ success: false, message: "Use the department head assignment endpoint to assign this role." });
      }
      if (current.data.role === "department_head" && Object.hasOwn(validated.changes, "department_id")) {
        return res.status(400).json({ success: false, message: "Use the department head endpoint to change this department assignment." });
      }
      if (
        current.data.role === "department_head" &&
        typeof validated.changes.role === "string" &&
        validated.changes.role !== "department_head" &&
        current.data.department_id
      ) {
        return res.status(409).json({ success: false, message: "Remove the department head assignment before changing this role." });
      }
      if (current.data.status === "pending_approval" && validated.changes.status === "active") {
        return res.status(400).json({ success: false, message: "Use the approval endpoint to activate a pending profile." });
      }

      const { data: profile, error } = await updateProfile(profileId, validated.changes);
      if (error) {
        logDatabaseError("Update profile failed", error);
        return res.status(500).json({ success: false, message: "Failed to update profile" });
      }
      if (!profile) {
        return res.status(404).json({ success: false, message: "Profile not found" });
      }
      return res.json({ success: true, profile: safeProfileResponse(profile) });
    } catch (error) {
      logUnexpectedError("Update profile failed", error);
      return res.status(500).json({ success: false, message: "Failed to update profile" });
    }
  },
);

router.post(
  "/profiles/onboard",
  requireAuth,
  requireRole("ceo"),
  async (req, res) => {
    if (!isRecord(req.body)) {
      return res.status(400).json({ success: false, message: "Request body must be a JSON object." });
    }
    const keys = Object.keys(req.body);
    if (keys.some((key) => !["auth_user_id", "full_name"].includes(key))) {
      return res.status(400).json({ success: false, message: "Only auth_user_id and full_name are accepted." });
    }
    const { auth_user_id: authUserId, full_name: fullName } = req.body;
    if (typeof authUserId !== "string" || !UUID_PATTERN.test(authUserId)) {
      return res.status(400).json({ success: false, message: "auth_user_id must be a UUID." });
    }
    if (typeof fullName !== "string" || fullName.trim().length < 1 || fullName.trim().length > 200) {
      return res.status(400).json({ success: false, message: "full_name must be a non-empty string of at most 200 characters." });
    }

    try {
      const { data: existing, error: existingError } = await profileAlreadyExists(authUserId);
      if (existingError) {
        logDatabaseError("Check existing profile failed", existingError);
        return res.status(500).json({ success: false, message: "Failed to onboard profile" });
      }
      if (existing) {
        return res.status(409).json({ success: false, message: "A profile already exists for this Auth user." });
      }

      const { data: authResult, error: authError } = await findAuthUser(authUserId);
      if (authError || !authResult.user) {
        if (authError) logDatabaseError("Find Auth user for onboarding failed", authError);
        return res.status(404).json({ success: false, message: "Existing Supabase Auth user not found." });
      }
      if (!authResult.user.email) {
        return res.status(400).json({ success: false, message: "Auth user must have an email address." });
      }

      const { data: profile, error } = await createPendingEmployeeProfile(
        authResult.user,
        fullName.trim(),
      );
      if (error) {
        if (error.code === "23505") {
          return res.status(409).json({ success: false, message: "A profile already exists for this Auth user." });
        }
        logDatabaseError("Create onboarding profile failed", error);
        return res.status(500).json({ success: false, message: "Failed to onboard profile" });
      }
      return res.status(201).json({ success: true, profile: safeProfileResponse(profile) });
    } catch (error) {
      logUnexpectedError("Onboard profile failed", error);
      return res.status(500).json({ success: false, message: "Failed to onboard profile" });
    }
  },
);

export default router;
