import type { NextFunction, Request, Response } from "express";
import { createUserSupabaseClient } from "../config/supabase-user.js";
import type { AuthenticatedRequest } from "./auth.js";

export function requireRole(...allowedRoles: string[]) {
  return async (
    req: Request,
    res: Response,
    next: NextFunction,
  ): Promise<void> => {
    try {
      const authenticatedRequest = req as AuthenticatedRequest;

      const supabase = createUserSupabaseClient(
        authenticatedRequest.accessToken,
      );

      const { data: profile, error } = await supabase
        .from("profiles")
        .select("role, status")
        .eq("id", authenticatedRequest.user.id)
        .single();

      if (error) {
        const code = typeof error.code === "string" ? error.code.slice(0, 40) : undefined;
        if (code !== "PGRST116" && code !== "42501") {
          console.error("Authorization profile lookup failed", { code: code ?? "unknown" });
          res.status(500).json({
            success: false,
            message: "Authorization service error",
          });
          return;
        }
        res.status(403).json({
          success: false,
          message: "User profile not found",
        });
        return;
      }
      if (!profile) {
        res.status(403).json({
          success: false,
          message: "User profile not found",
        });
        return;
      }

      if (profile.status !== "active") {
        res.status(403).json({
          success: false,
          message: "Account is not active",
        });
        return;
      }

      if (!allowedRoles.includes(profile.role)) {
        res.status(403).json({
          success: false,
          message: "You do not have permission to perform this action",
        });
        return;
      }

      next();
    } catch (error) {
      const name = error instanceof Error ? error.name : "UnknownError";
      const code = typeof error === "object" && error !== null && "code" in error && typeof error.code === "string"
        ? error.code.slice(0, 40)
        : undefined;
      console.error("Authorization check failed", { name, ...(code ? { code } : {}) });

      res.status(500).json({
        success: false,
        message: "Authorization service error",
      });
    }
  };
}
