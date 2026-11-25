import express from "express";
import cors from "cors";

import { requireAuth } from "./middleware/auth.js";
import { requireRole } from "./middleware/role.js";
import profilesRouter from "./routes/profiles.js";
import departmentsRouter from "./routes/departments.js";
import projectsRouter from "./routes/projects.js";
import tasksRouter from "./routes/tasks.js";
import meetingsRouter from "./routes/meetings.js";
import announcementsRouter from "./routes/announcements.js";
import notificationsRouter from "./routes/notifications.js";
import auditLogsRouter from "./routes/audit-logs.js";
import financeRouter from "./routes/finance.js";

const app = express();

app.use(cors());

app.use(express.json({ limit: "1mb" }));

app.get("/api/health", (_req, res) => {
  res.json({
    success: true,
    message: "ELMUAZ backend is running",
  });
});

app.use("/api", profilesRouter);
app.use("/api/departments", departmentsRouter);
app.use("/api/projects", projectsRouter);
app.use("/api/tasks", tasksRouter);
app.use("/api/meetings", meetingsRouter);
app.use("/api/announcements", announcementsRouter);
app.use("/api/notifications", notificationsRouter);
app.use("/api/audit-logs", auditLogsRouter);
app.use("/api/finance", financeRouter);

app.get(
  "/api/admin-test",
  requireAuth,
  requireRole("ceo"),
  (_req, res) => {
    res.json({
      success: true,
      message: "Admin authorization successful",
    });
  },
);

app.use((_req, res) => {
  res.status(404).json({ success: false, message: "Route not found" });
});

app.use((error: unknown, _req: express.Request, res: express.Response, next: express.NextFunction) => {
  if (res.headersSent) return next(error);
  const details = typeof error === "object" && error !== null ? error as { type?: unknown; status?: unknown } : {};
  if (details.type === "entity.parse.failed") {
    return res.status(400).json({ success: false, message: "Malformed JSON request body." });
  }
  if (details.type === "entity.too.large" || details.status === 413) {
    return res.status(413).json({ success: false, message: "Request body is too large." });
  }
  const name = error instanceof Error ? error.name : "UnknownError";
  console.error("Unhandled request error", { name });
  return res.status(500).json({ success: false, message: "Unexpected server error" });
});

export default app;
