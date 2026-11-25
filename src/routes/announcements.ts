import { Router, type Response } from "express";
import { requireAuth, type AuthenticatedRequest } from "../middleware/auth.js";
import { requireRole } from "../middleware/role.js";
import { recordActivityLog } from "../services/activity-log-service.js";
import {
  createAnnouncement,
  createAnnouncementAcknowledgment,
  getAnnouncement,
  getAnnouncementAcknowledgment,
  getAnnouncementActor,
  listAcknowledgedAnnouncementIds,
  listAnnouncements,
} from "../services/announcements-service.js";

const router = Router();
const STAFF_ROLES = ["ceo", "department_head", "accountant", "employee"];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
type Actor = { id: string; role: string; status: string };
function isRecord(value: unknown): value is Record<string, unknown> { return typeof value === "object" && value !== null && !Array.isArray(value); }
function logDb(context: string, error: { code?: string }) { console.error(context, { code: error.code }); }
function logUnexpected(context: string, error: unknown) { console.error(context, { name: error instanceof Error ? error.name : "UnknownError" }); }

async function loadActor(profileId: string, res: Response): Promise<Actor | null> {
  const { data, error } = await getAnnouncementActor(profileId);
  if (error) { logDb("Read announcement actor failed", error); res.status(500).json({ success: false, message: "Failed to authorize announcement operation" }); return null; }
  if (!data || data.status !== "active" || !STAFF_ROLES.includes(data.role)) {
    res.status(403).json({ success: false, message: "You do not have permission to access announcements." }); return null;
  }
  return data;
}

router.get("/", requireAuth, requireRole(...STAFF_ROLES), async (req, res) => {
  try {
    const actor = await loadActor((req as AuthenticatedRequest).user.id, res);
    if (!actor) return;
    const { data, error } = await listAnnouncements();
    if (error) { logDb("List announcements failed", error); return res.status(500).json({ success: false, message: "Failed to retrieve announcements" }); }
    const announcements = data ?? [];
    const acknowledgments = await listAcknowledgedAnnouncementIds(actor.id, announcements.map((row) => row.id));
    if (acknowledgments.error) { logDb("List announcement acknowledgments failed", acknowledgments.error); return res.status(500).json({ success: false, message: "Failed to retrieve announcements" }); }
    const acknowledged = new Set((acknowledgments.data ?? []).map((row) => row.announcement_id));
    return res.json({ success: true, announcements: announcements.map((row) => ({ ...row, acknowledged: acknowledged.has(row.id) })) });
  } catch (error) {
    logUnexpected("List announcements failed", error);
    return res.status(500).json({ success: false, message: "Failed to retrieve announcements" });
  }
});

router.post("/", requireAuth, requireRole("ceo"), async (req, res) => {
  if (!isRecord(req.body)) return res.status(400).json({ success: false, message: "Request body must be a JSON object." });
  const fields = new Set(["title", "content", "directive_code", "requires_acknowledgment"]);
  if (Object.keys(req.body).some((field) => !fields.has(field))) return res.status(400).json({ success: false, message: "One or more announcement fields are not allowed." });
  const { title, content, directive_code: directiveCode, requires_acknowledgment: requiresAcknowledgment } = req.body;
  if (typeof title !== "string" || title.trim().length < 1 || title.trim().length > 250) return res.status(400).json({ success: false, message: "title is required and must be at most 250 characters." });
  if (typeof content !== "string" || content.trim().length < 1 || content.length > 20000) return res.status(400).json({ success: false, message: "content is required and must be at most 20000 characters." });
  if (directiveCode !== undefined && directiveCode !== null && (typeof directiveCode !== "string" || directiveCode.length > 100)) return res.status(400).json({ success: false, message: "directive_code must be at most 100 characters or null." });
  if (requiresAcknowledgment !== undefined && typeof requiresAcknowledgment !== "boolean") return res.status(400).json({ success: false, message: "requires_acknowledgment must be a boolean." });

  try {
    const authenticated = req as AuthenticatedRequest;
    const actor = await loadActor(authenticated.user.id, res);
    if (!actor) return;
    if (actor.role !== "ceo") return res.status(403).json({ success: false, message: "Only the CEO may create announcements." });
    const { data, error } = await createAnnouncement({
      title: title.trim(), content: content.trim(),
      directive_code: typeof directiveCode === "string" ? directiveCode.trim() || null : null,
      requires_acknowledgment: requiresAcknowledgment ?? false,
      created_by: authenticated.user.id,
    });
    if (error) { logDb("Create announcement failed", error); return res.status(500).json({ success: false, message: "Failed to create announcement" }); }
    await recordActivityLog({ actorId: authenticated.user.id, action: "announcement.created", entityType: "announcement", entityId: data.id });
    return res.status(201).json({ success: true, announcement: data });
  } catch (error) {
    logUnexpected("Create announcement failed", error);
    return res.status(500).json({ success: false, message: "Failed to create announcement" });
  }
});

router.post("/:id/acknowledge", requireAuth, requireRole(...STAFF_ROLES), async (req, res) => {
  const announcementId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  if (!UUID.test(announcementId)) return res.status(400).json({ success: false, message: "Announcement id must be a UUID." });
  if (req.body !== undefined && (!isRecord(req.body) || Object.keys(req.body).length > 0)) return res.status(400).json({ success: false, message: "Acknowledgment does not accept request fields." });
  try {
    const authenticated = req as AuthenticatedRequest;
    const actor = await loadActor(authenticated.user.id, res);
    if (!actor) return;
    const { data: announcement, error } = await getAnnouncement(announcementId);
    if (error) { logDb("Read announcement for acknowledgment failed", error); return res.status(500).json({ success: false, message: "Failed to acknowledge announcement" }); }
    if (!announcement) return res.status(404).json({ success: false, message: "Announcement not found" });
    if (!announcement.requires_acknowledgment) return res.status(409).json({ success: false, message: "This announcement does not require acknowledgment." });
    const existing = await getAnnouncementAcknowledgment(announcementId, actor.id);
    if (existing.error) { logDb("Check announcement acknowledgment failed", existing.error); return res.status(500).json({ success: false, message: "Failed to acknowledge announcement" }); }
    if (existing.data) return res.json({ success: true, acknowledgment: existing.data, alreadyAcknowledged: true });
    const created = await createAnnouncementAcknowledgment(announcementId, actor.id);
    if (created.error) {
      if (created.error.code === "23505") {
        const raced = await getAnnouncementAcknowledgment(announcementId, actor.id);
        if (!raced.error && raced.data) return res.json({ success: true, acknowledgment: raced.data, alreadyAcknowledged: true });
      }
      logDb("Create announcement acknowledgment failed", created.error);
      return res.status(500).json({ success: false, message: "Failed to acknowledge announcement" });
    }
    await recordActivityLog({ actorId: actor.id, action: "announcement.acknowledged", entityType: "announcement", entityId: announcementId });
    return res.status(201).json({ success: true, acknowledgment: created.data, alreadyAcknowledged: false });
  } catch (error) {
    logUnexpected("Acknowledge announcement failed", error);
    return res.status(500).json({ success: false, message: "Failed to acknowledge announcement" });
  }
});

export default router;
