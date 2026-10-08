-- ELMUAZ EIMS
-- Migration 012: Activity / Audit Logs

CREATE TABLE activity_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  actor_id UUID
    REFERENCES profiles(id)
    ON DELETE SET NULL,

  action TEXT NOT NULL,
  entity_type TEXT NOT NULL,
  entity_id UUID,
  before_data JSONB,
  after_data JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_activity_logs_actor_id
ON activity_logs(actor_id);

CREATE INDEX idx_activity_logs_action
ON activity_logs(action);

CREATE INDEX idx_activity_logs_entity_type
ON activity_logs(entity_type);

CREATE INDEX idx_activity_logs_entity_id
ON activity_logs(entity_id);

CREATE INDEX idx_activity_logs_created_at
ON activity_logs(created_at);
