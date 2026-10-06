CREATE TYPE user_role AS ENUM (
  'admin',
  'employee'
);

CREATE TYPE user_status AS ENUM (
  'active',
  'suspended',
  'inactive'
);

CREATE TABLE profiles (
  id UUID PRIMARY KEY
    REFERENCES auth.users(id)
    ON DELETE CASCADE,

  full_name TEXT NOT NULL,
  email TEXT NOT NULL,
  phone TEXT,

  role user_role NOT NULL DEFAULT 'employee',

  job_title TEXT,
  avatar_url TEXT,

  status user_status NOT NULL DEFAULT 'active',

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_profiles_role
  ON profiles(role);

CREATE INDEX idx_profiles_status
  ON profiles(status);

CREATE OR REPLACE FUNCTION update_profiles_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

CREATE TRIGGER profiles_updated_at
BEFORE UPDATE ON profiles
FOR EACH ROW
EXECUTE FUNCTION update_profiles_updated_at();