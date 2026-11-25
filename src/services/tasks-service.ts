import { supabase } from "../config/supabase.js";

export const TASK_FIELDS =
  "id, title, description, assigned_to, assigned_by, priority, status, due_date, created_at, updated_at, stage, deliverable_url, project_id, task_submissions(id, content, submission_url, review_comment, status, submitted_at, reviewed_at)";

export async function getTaskActor(profileId: string) {
  return supabase
    .from("profiles")
    .select("id, role, status, department_id")
    .eq("id", profileId)
    .maybeSingle();
}

export async function listAllTasks() {
  return supabase
    .from("tasks")
    .select(TASK_FIELDS)
    .order("created_at", { ascending: false });
}

export async function listOwnTasks(profileId: string) {
  return supabase
    .from("tasks")
    .select(TASK_FIELDS)
    .or(`assigned_to.eq.${profileId},assigned_by.eq.${profileId}`)
    .order("created_at", { ascending: false });
}

export async function listDepartmentProjectTasks(departmentId: string) {
  const pageSize = 400;
  const tasks = new Map<string, Record<string, unknown>>();
  for (let offset = 0; ; offset += pageSize) {
    const { data: projects, error: projectError } = await supabase
      .from("projects")
      .select("id")
      .eq("department_id", departmentId)
      .order("id", { ascending: true })
      .range(offset, offset + pageSize - 1);
    if (projectError) return { data: null, error: projectError };
    const projectIds = (projects ?? []).map((project) => project.id as string);
    if (projectIds.length > 0) {
      const { data, error } = await supabase
        .from("tasks")
        .select(TASK_FIELDS)
        .in("project_id", projectIds)
        .order("created_at", { ascending: false });
      if (error) return { data: null, error };
      for (const task of data ?? []) tasks.set(task.id, task as Record<string, unknown>);
    }
    if (projectIds.length < pageSize) break;
  }
  return { data: [...tasks.values()], error: null };
}

export async function getTask(taskId: string) {
  return supabase
    .from("tasks")
    .select(TASK_FIELDS)
    .eq("id", taskId)
    .maybeSingle();
}

export async function listTaskComments(taskId: string) {
  return supabase
    .from("task_comments")
    .select("id, task_id, author_id, comment, created_at")
    .eq("task_id", taskId)
    .order("created_at", { ascending: true });
}

export async function createTaskComment(values: {
  task_id: string;
  author_id: string;
  comment: string;
}) {
  return supabase
    .from("task_comments")
    .insert(values)
    .select("id, task_id, author_id, comment, created_at")
    .single();
}

export async function getProject(projectId: string) {
  return supabase
    .from("projects")
    .select("id, department_id")
    .eq("id", projectId)
    .maybeSingle();
}

export async function getAssignee(profileId: string) {
  return supabase
    .from("profiles")
    .select("id, role, status, department_id")
    .eq("id", profileId)
    .maybeSingle();
}

export async function createTask(values: Record<string, unknown>) {
  return supabase
    .from("tasks")
    .insert(values)
    .select(TASK_FIELDS)
    .single();
}

export async function updateTaskStage(
  taskId: string,
  expectedStage: string,
  nextStage: string,
  status: string,
  extra: Record<string, unknown> = {},
) {
  return supabase
    .from("tasks")
    .update({ ...extra, stage: nextStage, status })
    .eq("id", taskId)
    .eq("stage", expectedStage)
    .select(TASK_FIELDS)
    .maybeSingle();
}

export async function insertSubmission(values: Record<string, unknown>) {
  return supabase
    .from("task_submissions")
    .insert(values)
    .select("id, task_id, submitted_by, content, submission_url, review_comment, status, reviewed_by, submitted_at, reviewed_at")
    .single();
}

export async function removeSubmission(submissionId: string) {
  return supabase.from("task_submissions").delete().eq("id", submissionId);
}

export async function latestPendingSubmission(taskId: string) {
  return supabase
    .from("task_submissions")
    .select("id, task_id, submitted_by, content, submission_url, status, submitted_at")
    .eq("task_id", taskId)
    .eq("status", "pending")
    .order("submitted_at", { ascending: false })
    .limit(1)
    .maybeSingle();
}

export async function reviewSubmission(
  submissionId: string,
  reviewerId: string,
  status: "approved" | "rejected",
  reviewComment: string | null,
) {
  return supabase
    .from("task_submissions")
    .update({
      status,
      review_comment: reviewComment,
      reviewed_by: reviewerId,
      reviewed_at: new Date().toISOString(),
    })
    .eq("id", submissionId)
    .eq("status", "pending")
    .select("id, task_id, submitted_by, content, submission_url, review_comment, status, reviewed_by, submitted_at, reviewed_at")
    .maybeSingle();
}

export async function restorePendingSubmission(submissionId: string) {
  return supabase
    .from("task_submissions")
    .update({ status: "pending", review_comment: null, reviewed_by: null, reviewed_at: null })
    .eq("id", submissionId);
}
