-- ============================================================
-- ELMUAZ EIMS
-- Migration 015: Security-Definer Helper Functions
-- ============================================================

-- 1. Helper: get_auth_role()
-- Returns the current authenticated user's user_role enum value, or NULL if not found.
CREATE OR REPLACE FUNCTION get_auth_role()
RETURNS user_role
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT role
  FROM profiles
  WHERE id = auth.uid();
$$;

-- 2. Helper: is_ceo()
-- Returns TRUE if the current user has the 'ceo' role.
CREATE OR REPLACE FUNCTION is_ceo()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(get_auth_role() = 'ceo'::user_role, false);
$$;

-- 3. Helper: is_accountant()
-- Returns TRUE if the current user has the 'accountant' role.
CREATE OR REPLACE FUNCTION is_accountant()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(get_auth_role() = 'accountant'::user_role, false);
$$;

-- 4. Helper: is_department_head()
-- Returns TRUE if the current user has the 'department_head' role.
CREATE OR REPLACE FUNCTION is_department_head()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(get_auth_role() = 'department_head'::user_role, false);
$$;

-- 5. Helper: is_department_head_for(target_department_id UUID)
-- Returns TRUE if the current user is a department_head for the specified department.
CREATE OR REPLACE FUNCTION is_department_head_for(target_department_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM profiles
    WHERE id = auth.uid()
      AND role = 'department_head'::user_role
      AND department_id = target_department_id
      AND target_department_id IS NOT NULL
  );
$$;

-- 6. Refinement: is_active_staff()
-- Re-declares is_active_staff() as STABLE to allow PostgreSQL query planner
-- to optimize execution in RLS row filters and prevent repeated evaluation per row.
CREATE OR REPLACE FUNCTION is_active_staff()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
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

-- Revoke all default public execution rights
REVOKE ALL ON FUNCTION get_auth_role() FROM PUBLIC;
REVOKE ALL ON FUNCTION is_ceo() FROM PUBLIC;
REVOKE ALL ON FUNCTION is_accountant() FROM PUBLIC;
REVOKE ALL ON FUNCTION is_department_head() FROM PUBLIC;
REVOKE ALL ON FUNCTION is_department_head_for(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION is_active_staff() FROM PUBLIC;

-- Grant execution strictly to authenticated users
GRANT EXECUTE ON FUNCTION get_auth_role() TO authenticated;
GRANT EXECUTE ON FUNCTION is_ceo() TO authenticated;
GRANT EXECUTE ON FUNCTION is_accountant() TO authenticated;
GRANT EXECUTE ON FUNCTION is_department_head() TO authenticated;
GRANT EXECUTE ON FUNCTION is_department_head_for(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION is_active_staff() TO authenticated;
