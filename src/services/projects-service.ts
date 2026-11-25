import { supabase } from "../config/supabase.js";

export const PROJECT_FIELDS =
  "id, name, department_id, description, progress_percent, status, lead_id, created_at, updated_at";

export async function getProjectActor(profileId: string) {
  return supabase
    .from("profiles")
    .select("id, role, status, department_id")
    .eq("id", profileId)
    .maybeSingle();
}

export async function listProjects(departmentId?: string) {
  const query = supabase
    .from("projects")
    .select(PROJECT_FIELDS)
    .order("created_at", { ascending: false });
  return departmentId ? query.eq("department_id", departmentId) : query;
}

export async function listProjectsForProfile(profileId: string) {
  const projectIds = new Set<string>();
  const pageSize = 400;
  const { data: ledProjects, error: leadError } = await supabase
    .from("projects")
    .select("id")
    .eq("lead_id", profileId);
  if (leadError) return { data: null, error: leadError };
  for (const project of ledProjects ?? []) projectIds.add(project.id);

  for (let offset = 0; ; offset += pageSize) {
    const { data: tasks, error } = await supabase
      .from("tasks")
      .select("project_id")
      .or(`assigned_to.eq.${profileId},assigned_by.eq.${profileId}`)
      .not("project_id", "is", null)
      .order("project_id", { ascending: true })
      .range(offset, offset + pageSize - 1);
    if (error) return { data: null, error };
    for (const task of tasks ?? []) {
      if (typeof task.project_id === "string") projectIds.add(task.project_id);
    }
    if ((tasks ?? []).length < pageSize) break;
  }
  if (projectIds.size === 0) return { data: [], error: null };
  return supabase.from("projects")
    .select(PROJECT_FIELDS)
    .in("id", [...projectIds])
    .order("created_at", { ascending: false });
}

export async function profileHasProjectTask(profileId: string, projectId: string) {
  return supabase.from("tasks").select("id")
    .eq("project_id", projectId)
    .or(`assigned_to.eq.${profileId},assigned_by.eq.${profileId}`)
    .limit(1)
    .maybeSingle();
}

export async function getProject(projectId: string) {
  return supabase
    .from("projects")
    .select(PROJECT_FIELDS)
    .eq("id", projectId)
    .maybeSingle();
}

export async function listKnownProjectStatuses() {
  return supabase.from("projects").select("status");
}

export async function departmentExists(departmentId: string) {
  return supabase
    .from("departments")
    .select("id")
    .eq("id", departmentId)
    .maybeSingle();
}

export async function getProjectLead(profileId: string) {
  return supabase
    .from("profiles")
    .select("id, status, department_id")
    .eq("id", profileId)
    .maybeSingle();
}

export async function createProject(values: Record<string, unknown>) {
  return supabase
    .from("projects")
    .insert(values)
    .select(PROJECT_FIELDS)
    .single();
}

export async function updateProject(projectId: string, values: Record<string, unknown>) {
  return supabase
    .from("projects")
    .update(values)
    .eq("id", projectId)
    .select(PROJECT_FIELDS)
    .maybeSingle();
}

export async function deleteProject(projectId: string) {
  return supabase
    .from("projects")
    .delete()
    .eq("id", projectId)
    .select("id")
    .maybeSingle();
}
