import { Router } from "express";
import { requireAuth } from "../middleware/auth.js";
import { requireRole } from "../middleware/role.js";
import { listAuditLogs } from "../services/activity-log-service.js";

const router = Router();

router.get("/", requireAuth, requireRole("ceo"), async (_req, res) => {
  try {
    const { data, error } = await listAuditLogs();
    if (error) {
      console.error("List audit logs failed", { code: error.code });
      return res.status(500).json({ success: false, message: "Failed to retrieve audit logs" });
    }
    return res.json({ success: true, audit_logs: data ?? [] });
  } catch (error) {
    console.error("List audit logs failed", { name: error instanceof Error ? error.name : "UnknownError" });
    return res.status(500).json({ success: false, message: "Failed to retrieve audit logs" });
  }
});

export default router;
