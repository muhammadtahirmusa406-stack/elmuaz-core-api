import { Router, type Response } from "express";
import { requireAuth, type AuthenticatedRequest } from "../middleware/auth.js";
import { requireRole } from "../middleware/role.js";
import { recordActivityLog } from "../services/activity-log-service.js";
import {
  getNotificationActor,
  listOwnedNotifications,
  listProfileNotifications,
  markProfileNotificationsRead,
} from "../services/notifications-service.js";

const router = Router();
const STAFF_ROLES = ["ceo", "department_head", "accountant", "employee"];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
type Actor = { id: string; role: string; status: string };
function isRecord(value: unknown): value is Record<string, unknown> { return typeof value === "object" && value !== null && !Array.isArray(value); }
function logDb(context: string, error: { code?: string }) { console.error(context, { code: error.code }); }
function logUnexpected(context: string, error: unknown) { console.error(context, { name: error instanceof Error ? error.name : "UnknownError" }); }

async function loadActor(profileId: string, res: Response): Promise<Actor | null> {
  const { data, error } = await getNotificationActor(profileId);
  if (error) { logDb("Read notification actor failed", error); res.status(500).json({ success: false, message: "Failed to authorize notification operation" }); return null; }
  if (!data || data.status !== "active" || !STAFF_ROLES.includes(data.role)) {
    res.status(403).json({ success: false, message: "You do not have permission to access notifications." }); return null;
  }
  return data;
}

router.get("/", requireAuth, requireRole(...STAFF_ROLES), async (req, res) => {
  try {
    const actor = await loadActor((req as AuthenticatedRequest).user.id, res);
    if (!actor) return;
    const { data, error } = await listProfileNotifications(actor.id);
    if (error) { logDb("List notifications failed", error); return res.status(500).json({ success: false, message: "Failed to retrieve notifications" }); }
    return res.json({ success: true, notifications: data ?? [] });
  } catch (error) {
    logUnexpected("List notifications failed", error);
    return res.status(500).json({ success: false, message: "Failed to retrieve notifications" });
  }
});

router.patch("/mark-read", requireAuth, requireRole(...STAFF_ROLES), async (req, res) => {
  if (!isRecord(req.body) || Object.keys(req.body).some((key) => key !== "notification_ids" && key !== "is_read")) {
    return res.status(400).json({ success: false, message: "Only notification_ids and is_read are accepted." });
  }
  const ids = req.body.notification_ids;
  if (!Array.isArray(ids) || ids.length < 1 || ids.length > 100 || ids.some((id) => typeof id !== "string" || !UUID.test(id))) {
    return res.status(400).json({ success: false, message: "notification_ids must contain 1 to 100 UUIDs." });
  }
  if (new Set(ids).size !== ids.length) return res.status(400).json({ success: false, message: "notification_ids must not contain duplicates." });
  if (req.body.is_read !== undefined && req.body.is_read !== true) return res.status(400).json({ success: false, message: "is_read must be true for this endpoint." });

  try {
    const authenticated = req as AuthenticatedRequest;
    const actor = await loadActor(authenticated.user.id, res);
    if (!actor) return;
    const owned = await listOwnedNotifications(actor.id, ids as string[]);
    if (owned.error) { logDb("Validate notification ownership failed", owned.error); return res.status(500).json({ success: false, message: "Failed to update notifications" }); }
    if ((owned.data ?? []).length !== ids.length) return res.status(404).json({ success: false, message: "One or more notifications were not found." });
    const { data, error } = await markProfileNotificationsRead(actor.id, ids as string[]);
    if (error) { logDb("Mark notifications read failed", error); return res.status(500).json({ success: false, message: "Failed to update notifications" }); }
    await recordActivityLog({ actorId: actor.id, action: "notification.marked_read", entityType: "notification", entityId: ids.length === 1 ? ids[0] as string : null });
    return res.json({ success: true, notifications: data ?? [] });
  } catch (error) {
    logUnexpected("Mark notifications read failed", error);
    return res.status(500).json({ success: false, message: "Failed to update notifications" });
  }
});

export default router;
