-- ELMUAZ EIMS
-- Migration 009: Finance

CREATE TYPE payment_type AS ENUM (
  'salary',
  'contract_payment',
  'vendor_expense',
  'bonus'
);

CREATE TYPE payment_status AS ENUM (
  'pending',
  'success',
  'failed'
);

CREATE TABLE treasury (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  operational_capital NUMERIC(15,2) NOT NULL DEFAULT 0,
  currency TEXT NOT NULL DEFAULT 'NGN',
  reconciled_with TEXT,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE payment_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reference TEXT NOT NULL UNIQUE,
  payment_type payment_type NOT NULL,
  recipient_name TEXT NOT NULL,
  recipient_id UUID REFERENCES profiles(id),
  amount NUMERIC(15,2) NOT NULL CHECK (amount > 0),
  memo TEXT,
  channel TEXT,
  status payment_status NOT NULL DEFAULT 'pending',
  authorized_by UUID NOT NULL REFERENCES profiles(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_payment_transactions_reference
ON payment_transactions(reference);

CREATE INDEX idx_payment_transactions_recipient_id
ON payment_transactions(recipient_id);

CREATE INDEX idx_payment_transactions_status
ON payment_transactions(status);

CREATE INDEX idx_payment_transactions_created_at
ON payment_transactions(created_at);

CREATE OR REPLACE FUNCTION update_treasury_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

CREATE TRIGGER treasury_updated_at
BEFORE UPDATE ON treasury
FOR EACH ROW
EXECUTE FUNCTION update_treasury_updated_at();
