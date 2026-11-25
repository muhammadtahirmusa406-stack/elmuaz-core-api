import { randomUUID } from "node:crypto";
import { Router } from "express";
import { requireAuth, type AuthenticatedRequest } from "../middleware/auth.js";
import { requireRole } from "../middleware/role.js";
import { recordActivityLog } from "../services/activity-log-service.js";
import {
  centsToDecimal,
  countTransactions,
  createPendingDisbursement,
  decimalToCents,
  getFinanceRecipient,
  listTransactions,
  listTreasuryAccounts,
  PAYMENT_STATUSES,
  PAYMENT_TYPES,
  refundTreasuryFunds,
  reserveTreasuryFunds,
} from "../services/finance-service.js";

const router = Router();
const FINANCE_ROLES = ["ceo", "accountant"];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const MAX_NUMERIC_15_2_CENTS = 999999999999999n;
function isRecord(value: unknown): value is Record<string, unknown> { return typeof value === "object" && value !== null && !Array.isArray(value); }
function logDb(context: string, error: { code?: string }) { console.error(context, { code: error.code }); }
function logUnexpected(context: string, error: unknown) { console.error(context, { name: error instanceof Error ? error.name : "UnknownError" }); }

router.get("/metrics", requireAuth, requireRole(...FINANCE_ROLES), async (_req, res) => {
  try {
    const [treasury, pending, success, failed, total] = await Promise.all([
      listTreasuryAccounts(),
      countTransactions("pending"),
      countTransactions("success"),
      countTransactions("failed"),
      countTransactions(),
    ]);
    for (const result of [treasury, pending, success, failed, total]) {
      if (result.error) { logDb("Read finance metrics failed", result.error); return res.status(500).json({ success: false, message: "Failed to retrieve finance metrics" }); }
    }
    return res.json({
      success: true,
      treasury_balances: (treasury.data ?? []).map((account) => ({
        currency: account.currency,
        balance: String(account.operational_capital),
        updated_at: account.updated_at,
      })),
      transaction_counts: {
        total: total.count ?? 0,
        pending: pending.count ?? 0,
        success: success.count ?? 0,
        failed: failed.count ?? 0,
      },
    });
  } catch (error) {
    logUnexpected("Read finance metrics failed", error);
    return res.status(500).json({ success: false, message: "Failed to retrieve finance metrics" });
  }
});

router.get("/transactions", requireAuth, requireRole(...FINANCE_ROLES), async (req, res) => {
  const allowedQuery = new Set(["limit", "offset", "status", "payment_type"]);
  if (Object.keys(req.query).some((key) => !allowedQuery.has(key))) {
    return res.status(400).json({ success: false, message: "One or more query parameters are not allowed." });
  }
  const parseInteger = (value: unknown, fallback: number, min: number, max: number) => {
    if (value === undefined) return fallback;
    if (typeof value !== "string" || !/^\d+$/.test(value)) return null;
    const parsed = Number(value);
    return Number.isSafeInteger(parsed) && parsed >= min && parsed <= max ? parsed : null;
  };
  const limit = parseInteger(req.query.limit, 50, 1, 100);
  const offset = parseInteger(req.query.offset, 0, 0, 100000);
  if (limit === null || offset === null) return res.status(400).json({ success: false, message: "limit or offset is invalid." });
  const status = req.query.status;
  const paymentType = req.query.payment_type;
  if (status !== undefined && (typeof status !== "string" || !PAYMENT_STATUSES.includes(status as typeof PAYMENT_STATUSES[number]))) {
    return res.status(400).json({ success: false, message: "status is invalid." });
  }
  if (paymentType !== undefined && (typeof paymentType !== "string" || !PAYMENT_TYPES.includes(paymentType as typeof PAYMENT_TYPES[number]))) {
    return res.status(400).json({ success: false, message: "payment_type is invalid." });
  }
  try {
    const { data, error, count } = await listTransactions({ limit, offset, status: status as string | undefined, paymentType: paymentType as string | undefined });
    if (error) { logDb("List finance transactions failed", error); return res.status(500).json({ success: false, message: "Failed to retrieve finance transactions" }); }
    return res.json({ success: true, transactions: data ?? [], pagination: { limit, offset, total: count ?? 0 } });
  } catch (error) {
    logUnexpected("List finance transactions failed", error);
    return res.status(500).json({ success: false, message: "Failed to retrieve finance transactions" });
  }
});

router.post("/disburse", requireAuth, requireRole(...FINANCE_ROLES), async (req, res) => {
  if (!isRecord(req.body)) return res.status(400).json({ success: false, message: "Request body must be a JSON object." });
  const allowed = new Set(["recipient_id", "amount", "payment_type", "memo"]);
  if (Object.keys(req.body).some((field) => !allowed.has(field))) return res.status(400).json({ success: false, message: "One or more disbursement fields are not allowed." });
  if (typeof req.body.recipient_id !== "string" || !UUID.test(req.body.recipient_id)) return res.status(400).json({ success: false, message: "recipient_id must be a profile UUID." });
  if (typeof req.body.payment_type !== "string" || !PAYMENT_TYPES.includes(req.body.payment_type as typeof PAYMENT_TYPES[number])) return res.status(400).json({ success: false, message: "payment_type is invalid." });
  if (typeof req.body.amount !== "string") return res.status(400).json({ success: false, message: "amount must be a decimal string with at most two fractional digits." });
  const amountCents = decimalToCents(req.body.amount);
  if (amountCents === null || amountCents <= 0n || amountCents > MAX_NUMERIC_15_2_CENTS) {
    return res.status(400).json({ success: false, message: "amount must be greater than zero and fit NUMERIC(15,2)." });
  }
  if (req.body.memo !== undefined && req.body.memo !== null && (typeof req.body.memo !== "string" || req.body.memo.length > 1000)) {
    return res.status(400).json({ success: false, message: "memo must be at most 1000 characters or null." });
  }

  try {
    const authenticated = req as AuthenticatedRequest;
    const { data: recipient, error: recipientError } = await getFinanceRecipient(req.body.recipient_id);
    if (recipientError) { logDb("Validate finance recipient failed", recipientError); return res.status(500).json({ success: false, message: "Failed to validate recipient" }); }
    if (!recipient || recipient.status !== "active") return res.status(400).json({ success: false, message: "recipient_id must identify an active profile." });

    const reservation = await reserveTreasuryFunds(amountCents);
    if (reservation.kind === "error") { logDb("Reserve treasury funds failed", reservation.error); return res.status(500).json({ success: false, message: "Failed to reserve treasury funds" }); }
    if (reservation.kind === "missing") return res.status(409).json({ success: false, message: "Treasury balance is not configured." });
    if (reservation.kind === "ambiguous") return res.status(409).json({ success: false, message: "Disbursement requires exactly one treasury currency account." });
    if (reservation.kind === "invalid_balance") return res.status(500).json({ success: false, message: "Treasury balance is invalid." });
    if (reservation.kind === "insufficient") return res.status(409).json({ success: false, message: "Insufficient treasury balance." });
    if (reservation.kind === "conflict") return res.status(409).json({ success: false, message: "Treasury balance changed; retry the disbursement." });

    const { data: transaction, error } = await createPendingDisbursement({
      reference: `EIMS-${randomUUID()}`,
      payment_type: req.body.payment_type,
      recipient_name: recipient.full_name,
      recipient_id: recipient.id,
      amount: centsToDecimal(amountCents),
      memo: typeof req.body.memo === "string" ? req.body.memo.trim() || null : null,
      authorized_by: authenticated.user.id,
    });
    if (error) {
      logDb("Create internal disbursement record failed", error);
      const refund = await refundTreasuryFunds(reservation.account.id, amountCents);
      if (refund.error) logDb("Restore treasury after failed disbursement record", refund.error);
      return res.status(500).json({ success: false, message: "Failed to create disbursement record" });
    }
    await recordActivityLog({ actorId: authenticated.user.id, action: "finance.disbursement_recorded", entityType: "payment_transaction", entityId: transaction.id });
    return res.status(201).json({
      success: true,
      message: "Internal disbursement record created and funds reserved; no external payment was initiated.",
      transaction,
    });
  } catch (error) {
    logUnexpected("Create internal disbursement record failed", error);
    return res.status(500).json({ success: false, message: "Failed to create disbursement record" });
  }
});

export default router;
