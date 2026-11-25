-- ELMUAZ EIMS
-- Migration 014: Complete User Roles

ALTER TYPE user_role
ADD VALUE IF NOT EXISTS 'department_head';

ALTER TYPE user_role
ADD VALUE IF NOT EXISTS 'accountant';
