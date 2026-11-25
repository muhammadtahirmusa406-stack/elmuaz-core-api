import { createNotification } from "../services/notifications-service.js";
import { Router, type Response } from "express";
import { requireAuth, type AuthenticatedRequest } from "../middleware/auth.js";
import { requireRole } from "../middleware/role.js";
import { isValidIsoDateTime } from "../utils/validation.js";
import {
  createTask,
  createTaskComment,
  getAssignee,
  getProject,
  getTask,
  getTaskActor,
  insertSubmission,
  latestPendingSubmission,
  listAllTasks,
  listDepartmentProjectTasks,
  listOwnTasks,
  listTaskComments,
  removeSubmission,
  restorePendingSubmission,
  reviewSubmission,
  updateTaskStage,
} from "../services/tasks-service.js";

const router = Router();
const STAFF_ROLES = ["ceo", "department_head", "accountant", "employee"];
const TASK_MANAGERS = ["ceo", "department_head"];
const ASSIGNEE_ROLES = ["employee", "department_head", "accountant"];
const PRIORITIES = ["low", "medium", "high", "urgent"];
const MAX_COMMENT_LENGTH = 5000;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const TASK_STAGES = [
  "draft",
  "assigned",
  "in_progress",
  "review_ready",
  "under_review",
  "needs_correction",
  "approved",
  "closed",
] as const;

type TaskActor = {
  id: string;
  role: string;
  status: string;
  department_id: string | null;
};

type TaskRecord = {
  id: string;
  assigned_to: string;
  assigned_by: string;
  stage: string;
  project_id: string | null;
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function logDatabaseError(context: string, error: { code?: string }) {
  console.error(context, { code: error.code });
}

function logUnexpectedError(context: string, error: unknown) {
  console.error(context, { name: error instanceof Error ? error.name : "UnknownError" });
}

function statusForStage(stage: string): string {
  if (stage === "draft" || stage === "assigned") return "assigned";
  if (stage === "in_progress" || stage === "needs_correction") return "in_progress";
  if (stage === "review_ready" || stage === "under_review") return "submitted";
  return "completed";
}

async function loadActor(req: AuthenticatedRequest, res: Response): Promise<TaskActor | null> {
  const { data: actor, error } = await getTaskActor(req.user.id);
  if (error) {
    logDatabaseError("Read task actor failed", error);
    res.status(500).json({ success: false, message: "Failed to authorize task operation" });
    return null;
  }
  if (!actor || actor.status !== "active" || !STAFF_ROLES.includes(actor.role)) {
    res.status(403).json({ success: false, message: "You do not have permission to access tasks." });
    return null;
  }
  return actor;
}

function validateTaskCreation(body: Record<string, unknown>) {
  const allowed = new Set([
    "title",
    "description",
    "assigned_to",
    "priority",
    "due_date",
    "project_id",
    "stage",
  ]);
  if (Object.keys(body).some((field) => !allowed.has(field))) {
    return { error: "One or more task fields are not allowed." } as const;
  }

  if (typeof body.title !== "string" || body.title.trim().length < 1 || body.title.trim().length > 300) {
    return { error: "title is required and must be at most 300 characters." } as const;
  }
  if (body.description !== undefined && body.description !== null &&
      (typeof body.description !== "string" || body.description.length > 10000)) {
    return { error: "description must be a string of at most 10000 characters or null." } as const;
  }
  if (typeof body.assigned_to !== "string" || !UUID_PATTERN.test(body.assigned_to)) {
    return { error: "assigned_to must be a UUID." } as const;
  }
  const priority = body.priority ?? "medium";
  if (typeof priority !== "string" || !PRIORITIES.includes(priority)) {
    return { error: "priority must be low, medium, high, or urgent." } as const;
  }
  let dueDate: string | null = null;
  if (body.due_date !== undefined && body.due_date !== null) {
    if (typeof body.due_date !== "string" || !isValidIsoDateTime(body.due_date)) {
      return { error: "due_date must be a valid ISO 8601 datetime with a timezone, or null." } as const;
    }
    dueDate = new Date(body.due_date).toISOString();
  }
  let projectId: string | null = null;
  if (body.project_id !== undefined && body.project_id !== null) {
    if (typeof body.project_id !== "string" || !UUID_PATTERN.test(body.project_id)) {
      return { error: "project_id must be a UUID or null." } as const;
    }
    projectId = body.project_id;
  }
  const stage = body.stage ?? "assigned";
  if (stage !== "draft" && stage !== "assigned") {
    return { error: "New tasks may start only in draft or assigned stage." } as const;
  }

  return {
    values: {
      title: body.title.trim(),
      description: typeof body.description === "string" ? body.description.trim() || null : null,
      assigned_to: body.assigned_to,
      priority,
      due_date: dueDate,
      project_id: projectId,
      stage,
      status: statusForStage(stage),
    },
  } as const;
}

async function hasProjectDepartmentAccess(actor: TaskActor, task: TaskRecord): Promise<boolean> {
  if (actor.role === "ceo") return true;
  if (actor.role !== "department_head" || !actor.department_id || !task.project_id) return false;
  const { data: project, error } = await getProject(task.project_id);
  return !error && project?.department_id === actor.department_id;
}

async function mayReviewTask(actor: TaskActor, task: TaskRecord): Promise<boolean> {
  if (actor.id === task.assigned_to) return false;
  return hasProjectDepartmentAccess(actor, task);
}

async function taskIsVisible(actor: TaskActor, task: TaskRecord): Promise<boolean> {
  if (actor.role === "ceo" || task.assigned_to === actor.id || task.assigned_by === actor.id) return true;
  return actor.role === "department_head" && hasProjectDepartmentAccess(actor, task);
}

router.get("/", requireAuth, requireRole(...STAFF_ROLES), async (req, res) => {
  try {
    const actor = await loadActor(req as AuthenticatedRequest, res);
    if (!actor) return;

    let tasks: Record<string, unknown>[];
    if (actor.role === "ceo") {
      const { data, error } = await listAllTasks();
      if (error) {
        logDatabaseError("List tasks failed", error);
        return res.status(500).json({ success: false, message: "Failed to retrieve tasks" });
      }
      tasks = (data ?? []) as Record<string, unknown>[];
    } else {
      const [ownResult, departmentResult] = await Promise.all([
        listOwnTasks(actor.id),
        actor.role === "department_head" && actor.department_id
          ? listDepartmentProjectTasks(actor.department_id)
          : Promise.resolve({ data: [], error: null }),
      ]);
      if (ownResult.error || departmentResult.error) {
        const error = ownResult.error ?? departmentResult.error;
        if (error) logDatabaseError("List tasks failed", error);
        return res.status(500).json({ success: false, message: "Failed to retrieve tasks" });
      }
      const combined = new Map<string, Record<string, unknown>>();
      for (const task of ownResult.data ?? []) combined.set(task.id, task as Record<string, unknown>);
      for (const task of departmentResult.data ?? []) combined.set(task.id as string, task);
      tasks = [...combined.values()].sort((a, b) =>
        String(b.created_at).localeCompare(String(a.created_at)),
      );
    }
    return res.json({ success: true, tasks });
  } catch (error) {
    logUnexpectedError("List tasks failed", error);
    return res.status(500).json({ success: false, message: "Failed to retrieve tasks" });
  }
});

router.get("/:id/comments", requireAuth, requireRole(...STAFF_ROLES), async (req, res) => {
  const taskId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  if (!UUID_PATTERN.test(taskId)) {
    return res.status(400).json({ success: false, message: "Task id must be a UUID." });
  }

  try {
    const actor = await loadActor(req as AuthenticatedRequest, res);
    if (!actor) return;
    const { data: task, error: taskError } = await getTask(taskId);
    if (taskError) {
      logDatabaseError("Read task for comments failed", taskError);
      return res.status(500).json({ success: false, message: "Failed to retrieve task comments" });
    }
    if (!task || !(await taskIsVisible(actor, task))) {
      return res.status(404).json({ success: false, message: "Task not found" });
    }

    const { data: comments, error } = await listTaskComments(taskId);
    if (error) {
      logDatabaseError("List task comments failed", error);
      return res.status(500).json({ success: false, message: "Failed to retrieve task comments" });
    }
    return res.json({ success: true, comments: comments ?? [] });
  } catch (error) {
    logUnexpectedError("List task comments failed", error);
    return res.status(500).json({ success: false, message: "Failed to retrieve task comments" });
  }
});

router.post("/:id/comments", requireAuth, requireRole(...STAFF_ROLES), async (req, res) => {
  const taskId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  if (!UUID_PATTERN.test(taskId)) {
    return res.status(400).json({ success: false, message: "Task id must be a UUID." });
  }
  if (!isRecord(req.body) || Object.keys(req.body).some((field) => field !== "comment")) {
    return res.status(400).json({ success: false, message: "Only the comment field is accepted." });
  }
  if (typeof req.body.comment !== "string" || req.body.comment.trim().length === 0) {
    return res.status(400).json({ success: false, message: "comment must not be empty." });
  }
  const comment = req.body.comment.trim();
  if (comment.length > MAX_COMMENT_LENGTH) {
    return res.status(400).json({ success: false, message: `comment must be at most ${MAX_COMMENT_LENGTH} characters.` });
  }

  try {
    const authenticatedRequest = req as AuthenticatedRequest;
    const actor = await loadActor(authenticatedRequest, res);
    if (!actor) return;
    const { data: task, error: taskError } = await getTask(taskId);
    if (taskError) {
      logDatabaseError("Read task before comment failed", taskError);
      return res.status(500).json({ success: false, message: "Failed to create task comment" });
    }
    if (!task || !(await taskIsVisible(actor, task))) {
      return res.status(404).json({ success: false, message: "Task not found" });
    }

    const { data, error } = await createTaskComment({
      task_id: taskId,
      author_id: authenticatedRequest.user.id,
      comment,
    });
    if (error) {
      logDatabaseError("Create task comment failed", error);
      return res.status(500).json({ success: false, message: "Failed to create task comment" });
    }
    return res.status(201).json({ success: true, comment: data });
  } catch (error) {
    logUnexpectedError("Create task comment failed", error);
    return res.status(500).json({ success: false, message: "Failed to create task comment" });
  }
});

router.post("/", requireAuth, requireRole(...TASK_MANAGERS), async (req, res) => {
  if (!isRecord(req.body)) {
    return res.status(400).json({ success: false, message: "Request body must be a JSON object." });
  }
  const validated = validateTaskCreation(req.body);
  if ("error" in validated) return res.status(400).json({ success: false, message: validated.error });

  try {
    const actor = await loadActor(req as AuthenticatedRequest, res);
    if (!actor) return;
    if (actor.role !== "ceo" && actor.role !== "department_head") {
      return res.status(403).json({ success: false, message: "You cannot create tasks." });
    }

    const values = { ...validated.values, assigned_by: actor.id };
    const assigneeResult = await getAssignee(values.assigned_to);
    if (assigneeResult.error) {
      logDatabaseError("Read task assignee failed", assigneeResult.error);
      return res.status(500).json({ success: false, message: "Failed to validate assignee" });
    }
    const assignee = assigneeResult.data;
    if (!assignee || assignee.status !== "active" || !ASSIGNEE_ROLES.includes(assignee.role)) {
      return res.status(400).json({ success: false, message: "Assignee must be an active staff profile." });
    }

    let projectDepartmentId: string | null = null;
    if (values.project_id) {
      const { data: project, error } = await getProject(values.project_id);
      if (error) {
        logDatabaseError("Read task project failed", error);
        return res.status(500).json({ success: false, message: "Failed to validate project" });
      }
      if (!project) return res.status(400).json({ success: false, message: "Project not found." });
      projectDepartmentId = project.department_id;
    }
    if (actor.role === "department_head") {
      if (!actor.department_id || !values.project_id || projectDepartmentId !== actor.department_id) {
        return res.status(403).json({ success: false, message: "Department heads may create tasks only for projects in their department." });
      }
    }
    if (projectDepartmentId && assignee.department_id !== projectDepartmentId) {
      return res.status(400).json({ success: false, message: "Assignee must belong to the project's department." });
    }

    const { data, error } = await createTask(values);
    if (error) {
      logDatabaseError("Create task failed", error);
      return res.status(500).json({ success: false, message: "Failed to create task" });
    }
    return res.status(201).json({ success: true, task: data });
  } catch (error) {
    logUnexpectedError("Create task failed", error);
    return res.status(500).json({ success: false, message: "Failed to create task" });
  }
});

router.patch("/:id/stage", requireAuth, requireRole(...STAFF_ROLES), async (req, res) => {
  const taskId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  if (!UUID_PATTERN.test(taskId)) {
    return res.status(400).json({ success: false, message: "Task id must be a UUID." });
  }
  if (!isRecord(req.body) || Object.keys(req.body).length !== 1 || !Object.hasOwn(req.body, "stage")) {
    return res.status(400).json({ success: false, message: "Provide only the requested stage." });
  }
  const nextStage = req.body.stage;
  if (typeof nextStage !== "string" || !TASK_STAGES.includes(nextStage as typeof TASK_STAGES[number])) {
    return res.status(400).json({ success: false, message: "stage is invalid." });
  }

  try {
    const actor = await loadActor(req as AuthenticatedRequest, res);
    if (!actor) return;
    const { data: task, error } = await getTask(taskId);
    if (error) {
      logDatabaseError("Read task before transition failed", error);
      return res.status(500).json({ success: false, message: "Failed to update task stage" });
    }
    if (!task) return res.status(404).json({ success: false, message: "Task not found" });
    if (!(await taskIsVisible(actor, task))) {
      return res.status(404).json({ success: false, message: "Task not found" });
    }

    const currentStage = task.stage;
    const validTransition =
      (currentStage === "draft" && nextStage === "assigned") ||
      (currentStage === "assigned" && nextStage === "in_progress") ||
      (currentStage === "review_ready" && nextStage === "under_review") ||
      (currentStage === "needs_correction" && nextStage === "in_progress") ||
      (currentStage === "approved" && nextStage === "closed");
    if (!validTransition) {
      if (currentStage === "in_progress" && nextStage === "review_ready") {
        return res.status(400).json({ success: false, message: "Submit work through POST /api/tasks/:id/submissions." });
      }
      return res.status(400).json({ success: false, message: "Invalid task stage transition." });
    }
    const authorizedTransition =
      (currentStage === "draft" && nextStage === "assigned" && await hasProjectDepartmentAccess(actor, task)) ||
      (currentStage === "assigned" && nextStage === "in_progress" && (actor.id === task.assigned_to || actor.role === "ceo")) ||
      (currentStage === "review_ready" && nextStage === "under_review" && await mayReviewTask(actor, task)) ||
      (currentStage === "needs_correction" && nextStage === "in_progress" && (actor.id === task.assigned_to || actor.role === "ceo")) ||
      (currentStage === "approved" && nextStage === "closed" && actor.id !== task.assigned_to && await hasProjectDepartmentAccess(actor, task));
    if (!authorizedTransition) {
      return res.status(403).json({ success: false, message: "You are not authorized to make this task stage transition." });
    }

    if (currentStage === "review_ready" && nextStage === "under_review") {
      const { data: submission, error: submissionError } = await latestPendingSubmission(taskId);
      if (submissionError) {
        logDatabaseError("Check task submission before review failed", submissionError);
        return res.status(500).json({ success: false, message: "Failed to update task stage" });
      }
      if (!submission || submission.submitted_by !== task.assigned_to) {
        return res.status(409).json({ success: false, message: "A pending submission from the assignee is required before review." });
      }
    }

    const { data, error: updateError } = await updateTaskStage(
      taskId,
      currentStage,
      nextStage,
      statusForStage(nextStage),
    );
    if (updateError) {
      logDatabaseError("Update task stage failed", updateError);
      return res.status(500).json({ success: false, message: "Failed to update task stage" });
    }
    if (!data) return res.status(409).json({ success: false, message: "Task stage changed; reload and try again." });
    return res.json({ success: true, task: data });
  } catch (error) {
    logUnexpectedError("Update task stage failed", error);
    return res.status(500).json({ success: false, message: "Failed to update task stage" });
  }
});

router.post("/:id/submissions", requireAuth, requireRole(...STAFF_ROLES), async (req, res) => {
  const taskId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  if (!UUID_PATTERN.test(taskId)) {
    return res.status(400).json({ success: false, message: "Task id must be a UUID." });
  }
  if (!isRecord(req.body) || Object.keys(req.body).some((key) => !["content", "submission_url"].includes(key))) {
    return res.status(400).json({ success: false, message: "Only content and submission_url are accepted." });
  }
  const content = req.body.content;
  const submissionUrl = req.body.submission_url;
  if (content !== undefined && content !== null &&
      (typeof content !== "string" || content.length > 10000)) {
    return res.status(400).json({ success: false, message: "content must be a string of at most 10000 characters or null." });
  }
  if (submissionUrl !== undefined && submissionUrl !== null &&
      (typeof submissionUrl !== "string" || submissionUrl.trim().length > 2048)) {
    return res.status(400).json({ success: false, message: "submission_url must be a string of at most 2048 characters or null." });
  }
  const normalizedContent = typeof content === "string" ? content.trim() || null : null;
  const normalizedUrl = typeof submissionUrl === "string" ? submissionUrl.trim() || null : null;
  if (!normalizedContent && !normalizedUrl) {
    return res.status(400).json({ success: false, message: "Provide content or submission_url." });
  }

  try {
    const actor = await loadActor(req as AuthenticatedRequest, res);
    if (!actor) return;
    const { data: task, error } = await getTask(taskId);
    if (error) {
      logDatabaseError("Read task before submission failed", error);
      return res.status(500).json({ success: false, message: "Failed to submit task work" });
    }
    if (!task) return res.status(404).json({ success: false, message: "Task not found" });
    if (actor.id !== task.assigned_to) {
      return res.status(403).json({ success: false, message: "Only the task assignee may submit work." });
    }
    if (task.stage !== "in_progress" && task.stage !== "needs_correction") {
      return res.status(409).json({ success: false, message: "Task is not accepting a submission in its current stage." });
    }

    const { data: submission, error: insertError } = await insertSubmission({
      task_id: taskId,
      submitted_by: actor.id,
      content: normalizedContent,
      submission_url: normalizedUrl,
      status: "pending",
    });
    if (insertError) {
      logDatabaseError("Create task submission failed", insertError);
      return res.status(500).json({ success: false, message: "Failed to submit task work" });
    }
    const extra = normalizedUrl ? { deliverable_url: normalizedUrl } : {};
    const { data: updatedTask, error: stageError } = await updateTaskStage(
      taskId,
      task.stage,
      "review_ready",
      statusForStage("review_ready"),
      extra,
    );
    if (stageError || !updatedTask) {
      const { error: rollbackError } = await removeSubmission(submission.id);
      if (rollbackError) logDatabaseError("Roll back task submission failed", rollbackError);
      if (stageError) {
        logDatabaseError("Set task review stage failed", stageError);
        return res.status(500).json({ success: false, message: "Failed to submit task work" });
      }
      return res.status(409).json({ success: false, message: "Task stage changed; reload and try again." });
    }
    return res.status(201).json({ success: true, task: updatedTask, submission });
  } catch (error) {
    logUnexpectedError("Create task submission failed", error);
    return res.status(500).json({ success: false, message: "Failed to submit task work" });
  }
});

router.post("/:id/review", requireAuth, requireRole(...STAFF_ROLES), async (req, res) => {
  const taskId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  if (!UUID_PATTERN.test(taskId)) {
    return res.status(400).json({ success: false, message: "Task id must be a UUID." });
  }
  if (!isRecord(req.body) || Object.keys(req.body).some((key) => key !== "decision" && key !== "review_comment")) {
    return res.status(400).json({ success: false, message: "Only decision and review_comment are accepted." });
  }
  const decision = req.body.decision;
  if (decision !== "approved" && decision !== "needs_correction") {
    return res.status(400).json({ success: false, message: "decision must be approved or needs_correction." });
  }
  const comment = req.body.review_comment;
  if (comment !== undefined && comment !== null &&
      (typeof comment !== "string" || comment.length > 10000)) {
    return res.status(400).json({ success: false, message: "review_comment must be a string of at most 10000 characters or null." });
  }
  const reviewComment = typeof comment === "string" ? comment.trim() || null : null;

  try {
    const actor = await loadActor(req as AuthenticatedRequest, res);
    if (!actor) return;
    const { data: task, error } = await getTask(taskId);
    if (error) {
      logDatabaseError("Read task before review failed", error);
      return res.status(500).json({ success: false, message: "Failed to review task" });
    }
    if (!task) return res.status(404).json({ success: false, message: "Task not found" });
    if (!(await mayReviewTask(actor, task))) {
      return res.status(actor.id === task.assigned_to ? 403 : 404).json({
        success: false,
        message: actor.id === task.assigned_to ? "Assignees cannot review or approve their own work." : "Task not found",
      });
    }
    if (task.stage !== "under_review") {
      return res.status(409).json({ success: false, message: "Task must be under_review before a decision can be recorded." });
    }
    const { data: submission, error: submissionError } = await latestPendingSubmission(taskId);
    if (submissionError) {
      logDatabaseError("Read submission for review failed", submissionError);
      return res.status(500).json({ success: false, message: "Failed to review task" });
    }
    if (!submission || submission.submitted_by !== task.assigned_to) {
      return res.status(409).json({ success: false, message: "A pending submission from the assignee is required." });
    }

    const submissionStatus = decision === "approved" ? "approved" : "rejected";
    const nextStage = decision === "approved" ? "approved" : "needs_correction";
    const { data: reviewed, error: reviewError } = await reviewSubmission(
      submission.id,
      actor.id,
      submissionStatus,
      reviewComment,
    );
    if (reviewError) {
      logDatabaseError("Record task review failed", reviewError);
      return res.status(500).json({ success: false, message: "Failed to review task" });
    }
    if (!reviewed) return res.status(409).json({ success: false, message: "Submission has already been reviewed." });

    const { data: updatedTask, error: stageError } = await updateTaskStage(
      taskId,
      "under_review",
      nextStage,
      statusForStage(nextStage),
    );
    if (stageError || !updatedTask) {
      const { error: rollbackError } = await restorePendingSubmission(submission.id);
      if (rollbackError) logDatabaseError("Roll back task review failed", rollbackError);
      if (stageError) {
        logDatabaseError("Update task after review failed", stageError);
        return res.status(500).json({ success: false, message: "Failed to review task" });
      }
      return res.status(409).json({ success: false, message: "Task stage changed; reload and try again." });
    }
        if (updatedTask.assigned_to) {
      const isApproved = decision === "approved";
      const notifTitle = isApproved ? `Task Approved: ${updatedTask.title}` : `Task Needs Correction: ${updatedTask.title}`;
      const notifMessage = reviewComment || (isApproved ? "Your submitted work has been approved." : "Please review the feedback and resubmit your deliverables.");
      try {
        await createNotification({
          profileId: updatedTask.assigned_to,
          title: notifTitle,
          message: notifMessage,
          type: isApproved ? "task_approved" : "task_feedback"
        });
      } catch (err) {
        console.error("[NOTIFICATIONS] Failed to dispatch review notification:", err);
      }
    }

    return res.json({ success: true, task: updatedTask, submission: reviewed });
  } catch (error) {
    logUnexpectedError("Review task failed", error);
    return res.status(500).json({ success: false, message: "Failed to review task" });
  }
});

export default router;
