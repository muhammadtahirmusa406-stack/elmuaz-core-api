import { supabase } from "../config/supabase.js";

export async function getNotificationActor(profileId: string) {
  return supabase.from("profiles").select("id, role, status").eq("id", profileId).maybeSingle();
}

export async function listProfileNotifications(profileId: string) {
  return supabase.from("notifications").select("id, title, message, type, is_read, created_at")
    .eq("profile_id", profileId).order("created_at", { ascending: false }).limit(500);
}

export async function listOwnedNotifications(profileId: string, ids: string[]) {
  return supabase.from("notifications").select("id").eq("profile_id", profileId).in("id", ids);
}

export async function markProfileNotificationsRead(profileId: string, ids: string[]) {
  return supabase.from("notifications").update({ is_read: true }).eq("profile_id", profileId).in("id", ids)
    .select("id, title, message, type, is_read, created_at");
}

export async function createNotification(payload: {
  profileId: string;
  title: string;
  message: string;
  type?: string;
}) {
  return supabase.from("notifications").insert({
    profile_id: payload.profileId,
    title: payload.title,
    message: payload.message,
    type: payload.type || "general"
  }).select("id, title, message, type, is_read, created_at").single();
}
