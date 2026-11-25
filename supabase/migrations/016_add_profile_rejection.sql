-- Add CEO rejection state and decision metadata for pending employee profiles.

ALTER TYPE user_status
ADD VALUE IF NOT EXISTS 'rejected';

ALTER TABLE profiles
ADD COLUMN IF NOT EXISTS rejected_by UUID,
ADD COLUMN IF NOT EXISTS rejected_at TIMESTAMPTZ;

ALTER TABLE profiles
ADD CONSTRAINT profiles_rejected_by_fkey
FOREIGN KEY (rejected_by)
REFERENCES profiles(id);
