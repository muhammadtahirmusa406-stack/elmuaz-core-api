import { supabase } from "../config/supabase.js";

type ActivityLogInput = {
  actorId: string;
  action: string;
  entityType: string;
  entityId: string | null;
};

// Server-only audit write. Keep payloads limited to identifiers and action names;
// never pass credentials, tokens, request bodies, or raw database errors here.
export async function recordActivityLog(input: ActivityLogInput): Promise<void> {
  try {
    const { error } = await supabase.from("activity_logs").insert({
      actor_id: input.actorId,
      action: input.action,
      entity_type: input.entityType,
      entity_id: input.entityId,
    });
    if (error) console.error("Audit log write failed", { code: error.code });
  } catch (error) {
    console.error("Audit log write failed", { name: error instanceof Error ? error.name : "UnknownError" });
  }
}

export async function listAuditLogs() {
  return supabase
    .from("activity_logs")
    .select("id, actor_id, action, entity_type, entity_id, created_at")
    .order("created_at", { ascending: false })
    .limit(500);
}
