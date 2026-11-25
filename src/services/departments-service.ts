import { supabase } from "../config/supabase.js";

export const DEPARTMENT_FIELDS = "id, name, code, head_id, created_at";

export async function listDepartments() {
  return supabase
    .from("departments")
    .select(DEPARTMENT_FIELDS)
    .order("name", { ascending: true });
}

export async function getDepartment(departmentId: string) {
  return supabase
    .from("departments")
    .select(DEPARTMENT_FIELDS)
    .eq("id", departmentId)
    .maybeSingle();
}

export async function createDepartment(name: string, code: string) {
  return supabase
    .from("departments")
    .insert({ name, code, head_id: null })
    .select(DEPARTMENT_FIELDS)
    .single();
}

export async function updateDepartment(departmentId: string, changes: Record<string, string>) {
  return supabase
    .from("departments")
    .update(changes)
    .eq("id", departmentId)
    .select(DEPARTMENT_FIELDS)
    .maybeSingle();
}

export async function removeDepartment(departmentId: string) {
  return supabase
    .from("departments")
    .delete()
    .eq("id", departmentId)
    .select("id")
    .maybeSingle();
}

export async function getProfileForDepartment(profileId: string) {
  return supabase
    .from("profiles")
    .select("id, role, status, department_id")
    .eq("id", profileId)
    .maybeSingle();
}

export async function getDepartmentHead(departmentId: string) {
  return supabase
    .from("departments")
    .select("id, head_id")
    .eq("id", departmentId)
    .maybeSingle();
}

export async function findOtherDepartmentForHead(profileId: string, departmentId: string) {
  return supabase
    .from("departments")
    .select("id")
    .eq("head_id", profileId)
    .neq("id", departmentId)
    .limit(1)
    .maybeSingle();
}

export async function setProfileDepartmentRole(
  profileId: string,
  role: string,
  departmentId: string | null,
  expected: { role: string; status: string; department_id: string | null },
) {
  let query = supabase
    .from("profiles")
    .update({ role, department_id: departmentId })
    .eq("id", profileId)
    .eq("role", expected.role)
    .eq("status", expected.status);
  query = expected.department_id === null
    ? query.is("department_id", null)
    : query.eq("department_id", expected.department_id);
  return query.select("id, role, department_id").maybeSingle();
}

export async function restoreProfileDepartmentRole(
  profileId: string,
  role: string,
  departmentId: string | null,
  expected: { role: string; status: string; department_id: string | null },
) {
  return setProfileDepartmentRole(profileId, role, departmentId, expected);
}

export async function setDepartmentHeadPointer(departmentId: string, headId: string | null, expectedHeadId: string | null) {
  let query = supabase
    .from("departments")
    .update({ head_id: headId })
    .eq("id", departmentId);
  query = expectedHeadId === null ? query.is("head_id", null) : query.eq("head_id", expectedHeadId);
  return query.select(DEPARTMENT_FIELDS).maybeSingle();
}
