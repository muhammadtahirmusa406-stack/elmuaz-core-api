-- ELMUAZ EIMS
-- Migration 010: Announcements and Acknowledgments

CREATE TABLE announcements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title TEXT NOT NULL,
  content TEXT NOT NULL,
  directive_code TEXT,
  requires_acknowledgment BOOLEAN NOT NULL DEFAULT FALSE,
  created_by UUID NOT NULL
    REFERENCES profiles(id)
    ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE announcement_acknowledgments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  announcement_id UUID NOT NULL
    REFERENCES announcements(id)
    ON DELETE CASCADE,
  profile_id UUID NOT NULL
    REFERENCES profiles(id)
    ON DELETE CASCADE,
  signed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT announcement_acknowledgments_unique
    UNIQUE (announcement_id, profile_id)
);

CREATE INDEX idx_announcements_created_by
ON announcements(created_by);

CREATE INDEX idx_announcements_created_at
ON announcements(created_at);

CREATE INDEX idx_announcement_acknowledgments_announcement_id
ON announcement_acknowledgments(announcement_id);

CREATE INDEX idx_announcement_acknowledgments_profile_id
ON announcement_acknowledgments(profile_id);
