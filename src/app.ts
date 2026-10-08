import express from "express";
import cors from "cors";

import {
  requireAuth,
  type AuthenticatedRequest,
} from "./middleware/auth.js";

import { requireRole } from "./middleware/role.js";

const app = express();

app.use(cors());

app.use(express.json());

app.get("/api/health", (_req, res) => {
  res.json({
    success: true,
    message: "ELMUAZ backend is running",
  });
});

app.get("/api/me", requireAuth, (req, res) => {
  const user = (req as AuthenticatedRequest).user;

  res.json({
    success: true,
    user,
  });
});

app.get(
  "/api/admin-test",
  requireAuth,
  requireRole("admin"),
  (_req, res) => {
    res.json({
      success: true,
      message: "Admin authorization successful",
    });
  },
);

export default app;