CREATE TYPE task_priority AS ENUM (
  'low',
  'medium',
  'high',
  'urgent'
);

CREATE TYPE task_status AS ENUM (
  'assigned',
  'accepted',
  'in_progress',
  'submitted',
  'completed'
);

CREATE TABLE tasks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  title TEXT NOT NULL,
  description TEXT,

  assigned_to UUID NOT NULL
    REFERENCES profiles(id),

  assigned_by UUID NOT NULL
    REFERENCES profiles(id),

  priority task_priority NOT NULL DEFAULT 'medium',
  status task_status NOT NULL DEFAULT 'assigned',

  due_date TIMESTAMPTZ,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_tasks_assigned_to
  ON tasks(assigned_to);

CREATE INDEX idx_tasks_assigned_by
  ON tasks(assigned_by);

CREATE INDEX idx_tasks_status
  ON tasks(status);

CREATE INDEX idx_tasks_due_date
  ON tasks(due_date);

CREATE OR REPLACE FUNCTION update_tasks_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

CREATE TRIGGER tasks_updated_at
BEFORE UPDATE ON tasks
FOR EACH ROW
EXECUTE FUNCTION update_tasks_updated_at();