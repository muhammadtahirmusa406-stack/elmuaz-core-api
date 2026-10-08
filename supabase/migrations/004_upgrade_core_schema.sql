-- ============================================================
-- ELMUAZ EIMS
-- Migration 004: Upgrade Core Schema
-- ============================================================

ALTER TYPE user_role
RENAME VALUE 'admin' TO 'ceo';

ALTER TYPE user_status
ADD VALUE IF NOT EXISTS 'pending_approval';

ALTER TYPE user_status
ADD VALUE IF NOT EXISTS 'probation';

ALTER TYPE user_status
ADD VALUE IF NOT EXISTS 'on_leave';

ALTER TYPE user_status
ADD VALUE IF NOT EXISTS 'suspended';

ALTER TYPE user_status
ADD VALUE IF NOT EXISTS 'terminated';

CREATE TYPE task_stage AS ENUM (
  'draft',
  'assigned',
  'in_progress',
  'review_ready',
  'under_review',
  'needs_correction',
  'approved',
  'closed'
);

ALTER TABLE profiles
ADD COLUMN IF NOT EXISTS department_id UUID,
ADD COLUMN IF NOT EXISTS salary NUMERIC(15,2),
ADD COLUMN IF NOT EXISTS auth_provider TEXT DEFAULT 'email',
ADD COLUMN IF NOT EXISTS approved_by UUID,
ADD COLUMN IF NOT EXISTS approved_at TIMESTAMPTZ;

ALTER TABLE tasks
ADD COLUMN IF NOT EXISTS stage task_stage,
ADD COLUMN IF NOT EXISTS deliverable_url TEXT;

UPDATE tasks
SET stage = CASE status
  WHEN 'assigned' THEN 'assigned'::task_stage
  WHEN 'accepted' THEN 'in_progress'::task_stage
  WHEN 'in_progress' THEN 'in_progress'::task_stage
  WHEN 'submitted' THEN 'review_ready'::task_stage
  WHEN 'completed' THEN 'approved'::task_stage
  ELSE 'draft'::task_stage
END
WHERE stage IS NULL;

ALTER TABLE tasks
ALTER COLUMN stage SET DEFAULT 'draft';

ALTER TABLE tasks
ALTER COLUMN stage SET NOT NULL;

ALTER TABLE task_submissions
ADD COLUMN IF NOT EXISTS submission_url TEXT;

ALTER TABLE profiles
ADD CONSTRAINT profiles_approved_by_fkey
FOREIGN KEY (approved_by)
REFERENCES profiles(id);

ALTER TABLE tasks
ADD CONSTRAINT tasks_stage_consistency
CHECK (stage IS NOT NULL);
