import { supabase } from "../config/supabase.js";

export const MEETING_FIELDS = "id, topic, type, meeting_time, agenda, meet_url, created_by, created_at";

export async function getMeetingActor(profileId: string) {
  return supabase.from("profiles").select("id, role, status, department_id").eq("id", profileId).maybeSingle();
}

export async function listAllMeetings() {
  return supabase.from("meetings").select(MEETING_FIELDS).order("meeting_time", { ascending: true }).limit(1000);
}

export async function listGeneralMeetings() {
  return supabase.from("meetings").select(MEETING_FIELDS).eq("type", "general").order("meeting_time", { ascending: true }).limit(1000);
}

export async function listMeetingsCreatedBy(profileId: string) {
  return supabase.from("meetings").select(MEETING_FIELDS).eq("created_by", profileId).order("meeting_time", { ascending: true }).limit(1000);
}

export async function listMeetingParticipantIds(profileId: string) {
  return supabase.from("meeting_participants").select("meeting_id").eq("profile_id", profileId);
}

export async function listMeetingsByIds(ids: string[]) {
  if (ids.length === 0) return { data: [], error: null };
  return supabase.from("meetings").select(MEETING_FIELDS).in("id", ids).order("meeting_time", { ascending: true }).limit(1000);
}

export async function getMeetingParticipantProfiles(profileIds: string[]) {
  if (profileIds.length === 0) return { data: [], error: null };
  return supabase.from("profiles").select("id, status, department_id").in("id", profileIds);
}

export async function createMeeting(values: Record<string, unknown>) {
  return supabase.from("meetings").insert(values).select(MEETING_FIELDS).single();
}

export async function insertMeetingParticipants(meetingId: string, profileIds: string[]) {
  if (profileIds.length === 0) return { data: [], error: null };
  return supabase.from("meeting_participants").insert(
    profileIds.map((profileId) => ({ meeting_id: meetingId, profile_id: profileId })),
  ).select("id, meeting_id, profile_id, attendance_status");
}

export async function deleteMeetingCreatedBy(meetingId: string, creatorId: string) {
  return supabase.from("meetings").delete().eq("id", meetingId).eq("created_by", creatorId);
}
