import { Router, type Response } from "express";
import { requireAuth, type AuthenticatedRequest } from "../middleware/auth.js";
import { requireRole } from "../middleware/role.js";
import { isValidIsoDateTime } from "../utils/validation.js";
import { recordActivityLog } from "../services/activity-log-service.js";
import {
  createMeeting,
  deleteMeetingCreatedBy,
  getMeetingActor,
  getMeetingParticipantProfiles,
  insertMeetingParticipants,
  listAllMeetings,
  listGeneralMeetings,
  listMeetingParticipantIds,
  listMeetingsByIds,
  listMeetingsCreatedBy,
} from "../services/meetings-service.js";

const router = Router();
const STAFF_ROLES = ["ceo", "department_head", "accountant", "employee"];
const MEETING_MANAGERS = ["ceo", "department_head"];
const TYPES = ["general", "department", "specific"];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

type Actor = { id: string; role: string; status: string; department_id: string | null };
function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function logDb(context: string, error: { code?: string }) { console.error(context, { code: error.code }); }
function logUnexpected(context: string, error: unknown) {
  console.error(context, { name: error instanceof Error ? error.name : "UnknownError" });
}
async function loadActor(req: AuthenticatedRequest, res: Response): Promise<Actor | null> {
  const { data, error } = await getMeetingActor(req.user.id);
  if (error) {
    logDb("Read meeting actor failed", error);
    res.status(500).json({ success: false, message: "Failed to authorize meeting operation" });
    return null;
  }
  if (!data || data.status !== "active" || !STAFF_ROLES.includes(data.role)) {
    res.status(403).json({ success: false, message: "You do not have permission to access meetings." });
    return null;
  }
  return data;
}

router.get("/", requireAuth, requireRole(...STAFF_ROLES), async (req, res) => {
  try {
    const actor = await loadActor(req as AuthenticatedRequest, res);
    if (!actor) return;
    if (actor.role === "ceo") {
      const { data, error } = await listAllMeetings();
      if (error) { logDb("List all meetings failed", error); return res.status(500).json({ success: false, message: "Failed to retrieve meetings" }); }
      return res.json({ success: true, meetings: data ?? [] });
    }

    const [general, created, memberships] = await Promise.all([
      listGeneralMeetings(),
      listMeetingsCreatedBy(actor.id),
      listMeetingParticipantIds(actor.id),
    ]);
    for (const result of [general, created, memberships]) {
      if (result.error) { logDb("List visible meetings failed", result.error); return res.status(500).json({ success: false, message: "Failed to retrieve meetings" }); }
    }
    const participantIds = (memberships.data ?? []).map((row) => row.meeting_id as string);
    const participantMeetings = await listMeetingsByIds(participantIds);
    if (participantMeetings.error) { logDb("List participant meetings failed", participantMeetings.error); return res.status(500).json({ success: false, message: "Failed to retrieve meetings" }); }
    const byId = new Map<string, Record<string, unknown>>();
    for (const meeting of [...(general.data ?? []), ...(created.data ?? []), ...(participantMeetings.data ?? [])]) {
      byId.set(meeting.id, meeting as Record<string, unknown>);
    }
    const meetings = [...byId.values()].sort((a, b) => String(a.meeting_time).localeCompare(String(b.meeting_time)));
    return res.json({ success: true, meetings });
  } catch (error) {
    logUnexpected("List meetings failed", error);
    return res.status(500).json({ success: false, message: "Failed to retrieve meetings" });
  }
});

router.post("/", requireAuth, requireRole(...MEETING_MANAGERS), async (req, res) => {
  if (!isRecord(req.body)) return res.status(400).json({ success: false, message: "Request body must be a JSON object." });
  const allowed = new Set(["topic", "type", "meeting_time", "agenda", "meet_url", "participants"]);
  if (Object.keys(req.body).some((field) => !allowed.has(field))) {
    return res.status(400).json({ success: false, message: "One or more meeting fields are not allowed." });
  }
  const { topic, meeting_time: meetingTime, agenda, meet_url: meetUrl, participants } = req.body;
  const type = req.body.type ?? "general";
  if (typeof topic !== "string" || topic.trim().length < 1 || topic.trim().length > 250) {
    return res.status(400).json({ success: false, message: "topic is required and must be at most 250 characters." });
  }
  if (typeof type !== "string" || !TYPES.includes(type)) return res.status(400).json({ success: false, message: "type must be general, department, or specific." });
  if (typeof meetingTime !== "string" || !isValidIsoDateTime(meetingTime)) {
    return res.status(400).json({ success: false, message: "meeting_time must be a valid ISO 8601 datetime with timezone." });
  }
  if (agenda !== undefined && agenda !== null && (typeof agenda !== "string" || agenda.length > 10000)) {
    return res.status(400).json({ success: false, message: "agenda must be a string of at most 10000 characters or null." });
  }
  if (meetUrl !== undefined && meetUrl !== null) {
    if (typeof meetUrl !== "string" || meetUrl.length > 2048) return res.status(400).json({ success: false, message: "meet_url must be a valid HTTP(S) URL or null." });
    try { const parsed = new URL(meetUrl); if (parsed.protocol !== "https:" && parsed.protocol !== "http:") throw new Error(); }
    catch { return res.status(400).json({ success: false, message: "meet_url must be a valid HTTP(S) URL or null." }); }
  }
  if (participants !== undefined && (!Array.isArray(participants) || participants.length > 200 || participants.some((id) => typeof id !== "string" || !UUID.test(id)))) {
    return res.status(400).json({ success: false, message: "participants must be an array of at most 200 profile UUIDs." });
  }
  const participantIds = (participants ?? []) as string[];
  if (new Set(participantIds).size !== participantIds.length) return res.status(400).json({ success: false, message: "participants must not contain duplicate profile IDs." });

  try {
    const authenticated = req as AuthenticatedRequest;
    const actor = await loadActor(authenticated, res);
    if (!actor) return;
    if (actor.role === "department_head") {
      if ((type !== "department" && type !== "specific") || !actor.department_id || participantIds.length === 0) {
        return res.status(403).json({ success: false, message: "Department Heads may create only explicitly scoped department or specific meetings." });
      }
    }
    if (participantIds.length > 0) {
      const { data: profiles, error } = await getMeetingParticipantProfiles(participantIds);
      if (error) { logDb("Validate meeting participants failed", error); return res.status(500).json({ success: false, message: "Failed to validate meeting participants" }); }
      if ((profiles ?? []).length !== participantIds.length || profiles?.some((p) => p.status !== "active")) {
        return res.status(400).json({ success: false, message: "Every participant must be an active profile." });
      }
      if (actor.role === "department_head" && profiles?.some((p) => p.department_id !== actor.department_id)) {
        return res.status(403).json({ success: false, message: "Department Heads may invite participants only from their department." });
      }
    }

    const { data: meeting, error } = await createMeeting({
      topic: topic.trim(), type, meeting_time: new Date(meetingTime).toISOString(),
      agenda: typeof agenda === "string" ? agenda.trim() || null : null,
      meet_url: typeof meetUrl === "string" ? meetUrl.trim() || null : null,
      created_by: authenticated.user.id,
    });
    if (error) { logDb("Create meeting failed", error); return res.status(500).json({ success: false, message: "Failed to create meeting" }); }
    const insertedParticipants = await insertMeetingParticipants(meeting.id, participantIds);
    if (insertedParticipants.error) {
      logDb("Add meeting participants failed", insertedParticipants.error);
      const rollback = await deleteMeetingCreatedBy(meeting.id, authenticated.user.id);
      if (rollback.error) logDb("Roll back meeting creation failed", rollback.error);
      return res.status(500).json({ success: false, message: "Failed to create meeting" });
    }
    await recordActivityLog({ actorId: authenticated.user.id, action: "meeting.created", entityType: "meeting", entityId: meeting.id });
    return res.status(201).json({ success: true, meeting, participants: insertedParticipants.data ?? [] });
  } catch (error) {
    logUnexpected("Create meeting failed", error);
    return res.status(500).json({ success: false, message: "Failed to create meeting" });
  }
});

export default router;
