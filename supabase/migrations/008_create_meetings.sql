-- ELMUAZ EIMS
-- Migration 008: Meetings

CREATE TYPE meeting_type AS ENUM (
  'general',
  'department',
  'specific'
);

CREATE TABLE meetings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  topic TEXT NOT NULL,
  type meeting_type NOT NULL DEFAULT 'general',
  meeting_time TIMESTAMPTZ NOT NULL,
  agenda TEXT,
  meet_url TEXT,
  created_by UUID NOT NULL REFERENCES profiles(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE meeting_participants (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  meeting_id UUID NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  profile_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  attendance_status TEXT NOT NULL DEFAULT 'invited',

  CONSTRAINT meeting_participants_unique
    UNIQUE (meeting_id, profile_id)
);

CREATE INDEX idx_meetings_created_by
ON meetings(created_by);

CREATE INDEX idx_meetings_meeting_time
ON meetings(meeting_time);

CREATE INDEX idx_meeting_participants_meeting_id
ON meeting_participants(meeting_id);

CREATE INDEX idx_meeting_participants_profile_id
ON meeting_participants(profile_id);
