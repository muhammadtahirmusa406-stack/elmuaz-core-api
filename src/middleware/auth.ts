import type { NextFunction, Request, Response } from "express";
import { createClient } from "@supabase/supabase-js";
import { env } from "../config/env.js";

const supabaseAuth = createClient(
  env.supabaseUrl,
  env.supabaseAnonKey,
  {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
    },
  },
);

export interface AuthenticatedRequest extends Request {
  user: {
    id: string;
    email?: string;
  };
  accessToken: string;
}

function logAuthFailure(error: unknown) {
  const name = error instanceof Error ? error.name : "UnknownError";
  const code = typeof error === "object" && error !== null && "code" in error && typeof error.code === "string"
    ? error.code.slice(0, 40)
    : undefined;
  console.error("Authentication verification failed", { name, ...(code ? { code } : {}) });
}

export async function requireAuth(
  req: Request,
  res: Response,
  next: NextFunction,
) {
  try {
    const authorization = req.headers.authorization;

    if (typeof authorization !== "string") {
      return res.status(401).json({
        success: false,
        message: "Authentication required",
      });
    }

    const match = /^Bearer\s+(\S+)$/i.exec(authorization.trim());
    const token = match?.[1];

    if (!token || token.length > 8192) {
      return res.status(401).json({
        success: false,
        message: "Authentication required",
      });
    }

    const {
      data: { user },
      error,
    } = await supabaseAuth.auth.getUser(token);

    if (error) {
      logAuthFailure(error);
      if (error.status !== undefined && error.status >= 500) {
        return res.status(503).json({ success: false, message: "Authentication service unavailable" });
      }
      if (error.name === "AuthRetryableFetchError") {
        return res.status(503).json({ success: false, message: "Authentication service unavailable" });
      }
      return res.status(401).json({
        success: false,
        message: "Invalid or expired access token",
      });
    }
    if (!user) {
      return res.status(401).json({
        success: false,
        message: "Invalid or expired access token",
      });
    }

    const authenticatedRequest = req as AuthenticatedRequest;

    authenticatedRequest.user = {
      id: user.id,
      email: user.email,
    };

    authenticatedRequest.accessToken = token;

    next();
  } catch (error) {
    logAuthFailure(error);

    return res.status(500).json({
      success: false,
      message: "Authentication service error",
    });
  }
}
