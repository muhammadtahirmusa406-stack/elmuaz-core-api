-- ELMUAZ EIMS
-- Migration 013: Security Functions

CREATE OR REPLACE FUNCTION is_active_staff()
RETURNS BOOLEAN
LANGUAGE SQL
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM profiles
    WHERE id = auth.uid()
      AND status = 'active'
  );
$$;

REVOKE ALL ON FUNCTION is_active_staff() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION is_active_staff()
TO authenticated;
