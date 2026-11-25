import { supabase } from "../config/supabase.js";

export const PAYMENT_TYPES = ["salary", "contract_payment", "vendor_expense", "bonus"] as const;
export const PAYMENT_STATUSES = ["pending", "success", "failed"] as const;
export const TRANSACTION_FIELDS = "id, reference, payment_type, recipient_name, recipient_id, amount, status, authorized_by, created_at";

export async function listTreasuryAccounts() {
  return supabase.from("treasury").select("id, operational_capital, currency, updated_at").order("currency");
}

export async function countTransactions(status?: string) {
  let query = supabase.from("payment_transactions").select("id", { count: "exact", head: true });
  if (status) query = query.eq("status", status);
  return query;
}

export async function listTransactions(options: {
  limit: number;
  offset: number;
  status?: string;
  paymentType?: string;
}) {
  let query = supabase.from("payment_transactions")
    .select(TRANSACTION_FIELDS, { count: "exact" })
    .order("created_at", { ascending: false })
    .range(options.offset, options.offset + options.limit - 1);
  if (options.status) query = query.eq("status", options.status);
  if (options.paymentType) query = query.eq("payment_type", options.paymentType);
  return query;
}

export async function getFinanceRecipient(profileId: string) {
  return supabase.from("profiles").select("id, full_name, status").eq("id", profileId).maybeSingle();
}

export async function reserveTreasuryFunds(amountCents: bigint) {
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const { data: accounts, error: readError } = await listTreasuryAccounts();
    if (readError) return { kind: "error" as const, error: readError };
    if (!accounts || accounts.length === 0) return { kind: "missing" as const };
    if (accounts.length !== 1) return { kind: "ambiguous" as const };

    const account = accounts[0];
    const balanceCents = decimalToCents(account.operational_capital);
    if (balanceCents === null) return { kind: "invalid_balance" as const };
    if (balanceCents < amountCents) return { kind: "insufficient" as const };
    const newBalance = centsToDecimal(balanceCents - amountCents);
    const { data, error } = await supabase.from("treasury")
      .update({ operational_capital: newBalance })
      .eq("id", account.id)
      .eq("operational_capital", String(account.operational_capital))
      .gte("operational_capital", centsToDecimal(amountCents))
      .select("id, operational_capital, currency, updated_at")
      .maybeSingle();
    if (error) return { kind: "error" as const, error };
    if (data) return { kind: "reserved" as const, account: data };
  }
  return { kind: "conflict" as const };
}

export async function refundTreasuryFunds(accountId: string, amountCents: bigint) {
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const { data: account, error: readError } = await supabase.from("treasury")
      .select("id, operational_capital")
      .eq("id", accountId)
      .maybeSingle();
    if (readError || !account) return { error: readError ?? { code: "TREASURY_NOT_FOUND" } };
    const balanceCents = decimalToCents(account.operational_capital);
    if (balanceCents === null) return { error: { code: "TREASURY_INVALID_BALANCE" } };
    const { data, error } = await supabase.from("treasury")
      .update({ operational_capital: centsToDecimal(balanceCents + amountCents) })
      .eq("id", accountId)
      .eq("operational_capital", String(account.operational_capital))
      .select("id")
      .maybeSingle();
    if (error) return { error };
    if (data) return { error: null };
  }
  return { error: { code: "TREASURY_REFUND_CONFLICT" } };
}

export async function createPendingDisbursement(values: {
  reference: string;
  payment_type: string;
  recipient_name: string;
  recipient_id: string;
  amount: string;
  memo: string | null;
  authorized_by: string;
}) {
  return supabase.from("payment_transactions").insert({ ...values, status: "pending" })
    .select(TRANSACTION_FIELDS).single();
}

export function decimalToCents(value: unknown): bigint | null {
  if (typeof value !== "string" && typeof value !== "number") return null;
  const text = String(value);
  const match = /^(0|[1-9]\d{0,12})(?:\.(\d{1,2}))?$/.exec(text);
  if (!match) return null;
  const whole = BigInt(match[1]);
  const fraction = BigInt((match[2] ?? "").padEnd(2, "0") || "0");
  return whole * 100n + fraction;
}

export function centsToDecimal(value: bigint): string {
  const whole = value / 100n;
  const fraction = String(value % 100n).padStart(2, "0");
  return `${whole}.${fraction}`;
}
