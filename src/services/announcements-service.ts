import { supabase } from "../config/supabase.js";

export const ANNOUNCEMENT_FIELDS = "id, title, content, directive_code, requires_acknowledgment, created_by, created_at";

export async function getAnnouncementActor(profileId: string) {
  return supabase.from("profiles").select("id, role, status").eq("id", profileId).maybeSingle();
}

export async function listAnnouncements() {
  return supabase.from("announcements").select(ANNOUNCEMENT_FIELDS).order("created_at", { ascending: false }).limit(1000);
}

export async function listAcknowledgedAnnouncementIds(profileId: string, announcementIds: string[]) {
  if (announcementIds.length === 0) return { data: [], error: null };
  return supabase.from("announcement_acknowledgments").select("announcement_id").eq("profile_id", profileId).in("announcement_id", announcementIds);
}

export async function createAnnouncement(values: Record<string, unknown>) {
  return supabase.from("announcements").insert(values).select(ANNOUNCEMENT_FIELDS).single();
}

export async function getAnnouncement(announcementId: string) {
  return supabase.from("announcements").select("id, requires_acknowledgment").eq("id", announcementId).maybeSingle();
}

export async function getAnnouncementAcknowledgment(announcementId: string, profileId: string) {
  return supabase.from("announcement_acknowledgments").select("id, announcement_id, profile_id, signed_at")
    .eq("announcement_id", announcementId).eq("profile_id", profileId).maybeSingle();
}

export async function createAnnouncementAcknowledgment(announcementId: string, profileId: string) {
  return supabase.from("announcement_acknowledgments").insert({ announcement_id: announcementId, profile_id: profileId })
    .select("id, announcement_id, profile_id, signed_at").single();
}
