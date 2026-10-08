-- ELMUAZ EIMS
-- Migration 007: Complete Missing Task Components

ALTER TABLE tasks
ADD COLUMN IF NOT EXISTS project_id UUID;

ALTER TABLE tasks
ADD CONSTRAINT tasks_project_id_fkey
FOREIGN KEY (project_id)
REFERENCES projects(id);

CREATE INDEX IF NOT EXISTS idx_tasks_project_id
ON tasks(project_id);

CREATE TABLE task_comments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id UUID NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  author_id UUID NOT NULL REFERENCES profiles(id),
  comment TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_task_comments_task_id
ON task_comments(task_id);

CREATE INDEX idx_task_comments_author_id
ON task_comments(author_id);
