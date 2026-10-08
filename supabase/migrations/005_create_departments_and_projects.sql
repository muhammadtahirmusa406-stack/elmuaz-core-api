-- ELMUAZ EIMS
-- Migration 005: Departments and Projects

CREATE TABLE departments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL UNIQUE,
  code TEXT NOT NULL UNIQUE,
  head_id UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE projects (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  department_id UUID REFERENCES departments(id),
  description TEXT,
  progress_percent INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'active',
  lead_id UUID REFERENCES profiles(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE profiles
ADD CONSTRAINT profiles_department_id_fkey
FOREIGN KEY (department_id)
REFERENCES departments(id);

ALTER TABLE departments
ADD CONSTRAINT departments_head_id_fkey
FOREIGN KEY (head_id)
REFERENCES profiles(id);

CREATE INDEX idx_departments_head_id ON departments(head_id);
CREATE INDEX idx_projects_department_id ON projects(department_id);
CREATE INDEX idx_projects_lead_id ON projects(lead_id);

CREATE OR REPLACE FUNCTION update_projects_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

CREATE TRIGGER projects_updated_at
BEFORE UPDATE ON projects
FOR EACH ROW
EXECUTE FUNCTION update_projects_updated_at();
