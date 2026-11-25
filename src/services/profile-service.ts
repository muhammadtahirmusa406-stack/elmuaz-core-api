import type { User } from "@supabase/supabase-js";
import { supabase } from "../config/supabase.js";

export const SAFE_PROFILE_FIELDS =
  "id, full_name, email, phone, role, job_title, avatar_url, status, department_id, created_at, updated_at";

export const SELF_EDITABLE_FIELDS = [
  "full_name",
  "phone",
  "job_title",
  "avatar_url",
] as const;

export const CEO_EDITABLE_FIELDS = [
  "role",
  "status",
  "salary",
  "department_id",
] as const;

export type OnboardAuthUser = User;

export async function listProfiles(includeNonActive: boolean) {
  const query = supabase
    .from("profiles")
    .select(SAFE_PROFILE_FIELDS)
    .order("full_name", { ascending: true });
  return includeNonActive ? query : query.eq("status", "active");
}

export async function listPendingProfiles() {
  return supabase
    .from("profiles")
    .select(SAFE_PROFILE_FIELDS)
    .eq("status", "pending_approval")
    .order("created_at", { ascending: true });
}

export async function getProfileById(profileId: string) {
  return supabase
    .from("profiles")
    .select("id, role, status, department_id")
    .eq("id", profileId)
    .maybeSingle();
}

export async function updateProfile(profileId: string, changes: Record<string, unknown>) {
  return supabase
    .from("profiles")
    .update(changes)
    .eq("id", profileId)
    .select(SAFE_PROFILE_FIELDS)
    .maybeSingle();
}

export async function approvePendingProfile(profileId: string, ceoId: string, approvedAt: string) {
  return supabase
    .from("profiles")
    .update({
      status: "active",
      approved_by: ceoId,
      approved_at: approvedAt,
    })
    .eq("id", profileId)
    .eq("status", "pending_approval")
    .select(SAFE_PROFILE_FIELDS)
    .maybeSingle();
}

export async function rejectPendingProfile(profileId: string, rejectedBy: string) {
  return supabase
    .from("profiles")
    .update({
      status: "rejected",
      rejected_by: rejectedBy,
      rejected_at: new Date().toISOString(),
    })
    .eq("id", profileId)
    .eq("status", "pending_approval")
    .select(`${SAFE_PROFILE_FIELDS}, rejected_by, rejected_at`)
    .maybeSingle();
}

export async function findAuthUser(authUserId: string) {
  return supabase.auth.admin.getUserById(authUserId);
}

export async function profileAlreadyExists(profileId: string) {
  return supabase
    .from("profiles")
    .select("id")
    .eq("id", profileId)
    .maybeSingle();
}

export async function createPendingEmployeeProfile(user: OnboardAuthUser, fullName: string) {
  const provider = user.app_metadata?.provider;
  const authProvider = typeof provider === "string" && provider.length > 0
    ? provider
    : "email";

  return supabase
    .from("profiles")
    .insert({
      id: user.id,
      full_name: fullName,
      email: user.email!,
      role: "employee",
      status: "pending_approval",
      auth_provider: authProvider,
      approved_by: null,
      approved_at: null,
    })
    .select(SAFE_PROFILE_FIELDS)
    .single();
}
