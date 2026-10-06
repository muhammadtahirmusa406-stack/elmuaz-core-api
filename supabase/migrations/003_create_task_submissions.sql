CREATE TYPE submission_status AS ENUM (
  'pending',
  'approved',
  'rejected'
);

CREATE TABLE task_submissions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  task_id UUID NOT NULL
    REFERENCES tasks(id)
    ON DELETE CASCADE,

  submitted_by UUID NOT NULL
    REFERENCES profiles(id),

  content TEXT,
  review_comment TEXT,

  status submission_status NOT NULL DEFAULT 'pending',

  reviewed_by UUID
    REFERENCES profiles(id),

  submitted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  reviewed_at TIMESTAMPTZ
);

CREATE INDEX idx_task_submissions_task_id
  ON task_submissions(task_id);

CREATE INDEX idx_task_submissions_submitted_by
  ON task_submissions(submitted_by);

CREATE INDEX idx_task_submissions_status
  ON task_submissions(status);