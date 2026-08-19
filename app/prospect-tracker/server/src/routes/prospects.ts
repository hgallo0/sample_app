import { Router } from "express";
import { pool } from "../db/pool.js";
import { logger } from "../logger.js";
import { prospectsCreatedTotal, stageTransitionsTotal, syntheticCheckTotal } from "../metrics.js";
import { isProspectStage, STAGES_REQUIRING_PROPOSAL_FIELDS, VALID_SERVICE_FEES } from "../stages.js";
import type { ProspectStage } from "../stages.js";

export const prospectsRouter = Router();

const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

function pgErrorToStatus(err: any): { status: number; message: string } {
  if (err?.code === "23505") return { status: 409, message: "A prospect with that email already exists." };
  if (err?.code === "23514") return { status: 400, message: "That value violates a database constraint." };
  if (err?.code === "23503") return { status: 400, message: "Referenced advisor does not exist." };
  return { status: 500, message: "Unexpected server error." };
}

function validateProposalFields(
  stage: ProspectStage,
  estimatedValue: number | null,
  serviceFee: number | null
): string | null {
  if (serviceFee !== null && !VALID_SERVICE_FEES.includes(serviceFee)) {
    return `service_fee must be one of: ${VALID_SERVICE_FEES.join(", ")}.`;
  }
  if (STAGES_REQUIRING_PROPOSAL_FIELDS.includes(stage) && (estimatedValue === null || serviceFee === null)) {
    return "estimated_value and service_fee are required once a prospect reaches the proposal stage.";
  }
  return null;
}

prospectsRouter.get("/", async (req, res, next) => {
  // Set by the Cloud Scheduler synthetic check (infra/main.tf) so its
  // requests are countable as a distinct outside-in signal, separate from
  // real advisor traffic hitting the same route. Targets this route rather
  // than /api/health specifically because health's SELECT 1 never touches
  // the prospects table - it wouldn't have caught this build's real
  // permission-denied incident, and this check should actually exercise
  // the dependency that broke.
  const isSynthetic = req.get("x-synthetic-check") === "true";
  try {
    const { rows } = await pool.query(
      `SELECT id, advisor_id, first_name, last_name, email, phone, stage,
              estimated_value, service_fee, notes, created_at, updated_at
       FROM prospects
       ORDER BY created_at DESC`
    );
    if (isSynthetic) syntheticCheckTotal.add(1, { result: "ok" });
    res.json(rows);
  } catch (err) {
    if (isSynthetic) syntheticCheckTotal.add(1, { result: "error" });
    next(err);
  }
});

prospectsRouter.post("/", async (req, res) => {
  const { advisor_id, first_name, last_name, email, phone, stage, estimated_value, service_fee, notes } = req.body ?? {};

  if (!advisor_id || !first_name?.trim() || !last_name?.trim() || !email?.trim()) {
    return res.status(400).json({ error: "advisor_id, first_name, last_name, and email are required." });
  }
  if (!EMAIL_RE.test(email)) {
    return res.status(400).json({ error: "Invalid email format." });
  }
  if (stage !== undefined && !isProspectStage(stage)) {
    return res.status(400).json({ error: "Invalid stage." });
  }

  const effectiveStage: ProspectStage = stage ?? "lead";
  const proposalError = validateProposalFields(effectiveStage, estimated_value ?? null, service_fee ?? null);
  if (proposalError) {
    return res.status(400).json({ error: proposalError });
  }

  try {
    const { rows } = await pool.query(
      `INSERT INTO prospects (advisor_id, first_name, last_name, email, phone, stage, estimated_value, service_fee, notes)
       VALUES ($1, $2, $3, $4, $5, COALESCE($6::prospect_stage, 'lead'), $7, $8, $9)
       RETURNING *`,
      [
        advisor_id,
        first_name.trim(),
        last_name.trim(),
        email.trim(),
        phone ?? null,
        stage ?? null,
        estimated_value ?? null,
        service_fee ?? null,
        notes ?? null,
      ]
    );
    prospectsCreatedTotal.add(1, { stage: rows[0].stage });
    logger.info("prospect created", { prospect_id: rows[0].id, stage: rows[0].stage });
    res.status(201).json(rows[0]);
  } catch (err: any) {
    const { status, message } = pgErrorToStatus(err);
    logger.error("prospect creation failed", { error: err?.message ?? String(err), pg_code: err?.code });
    res.status(status).json({ error: message });
  }
});

prospectsRouter.put("/:id", async (req, res) => {
  const { id } = req.params;
  const { first_name, last_name, email, phone, stage, estimated_value, service_fee, notes } = req.body ?? {};

  if (email !== undefined && !EMAIL_RE.test(email)) {
    return res.status(400).json({ error: "Invalid email format." });
  }
  if (stage !== undefined && !isProspectStage(stage)) {
    return res.status(400).json({ error: "Invalid stage." });
  }

  try {
    const existing = await pool.query(`SELECT stage, estimated_value, service_fee FROM prospects WHERE id = $1`, [id]);
    if (existing.rows.length === 0) return res.status(404).json({ error: "Prospect not found." });

    const effectiveStage: ProspectStage = stage ?? existing.rows[0].stage;
    const effectiveEstimatedValue = estimated_value ?? existing.rows[0].estimated_value;
    const effectiveServiceFee = service_fee ?? existing.rows[0].service_fee;
    const proposalError = validateProposalFields(
      effectiveStage,
      effectiveEstimatedValue === undefined ? null : effectiveEstimatedValue,
      effectiveServiceFee === undefined ? null : effectiveServiceFee
    );
    if (proposalError) {
      return res.status(400).json({ error: proposalError });
    }

    const { rows } = await pool.query(
      `UPDATE prospects SET
         first_name = COALESCE($2, first_name),
         last_name = COALESCE($3, last_name),
         email = COALESCE($4, email),
         phone = COALESCE($5, phone),
         stage = COALESCE($6, stage),
         estimated_value = COALESCE($7, estimated_value),
         service_fee = COALESCE($8, service_fee),
         notes = COALESCE($9, notes)
       WHERE id = $1
       RETURNING *`,
      [
        id,
        first_name ?? null,
        last_name ?? null,
        email ?? null,
        phone ?? null,
        stage ?? null,
        estimated_value ?? null,
        service_fee ?? null,
        notes ?? null,
      ]
    );
    if (stage !== undefined && stage !== existing.rows[0].stage) {
      stageTransitionsTotal.add(1, { from: existing.rows[0].stage, to: stage });
      logger.info("prospect stage transition", { prospect_id: id, from: existing.rows[0].stage, to: stage });
    }
    res.json(rows[0]);
  } catch (err: any) {
    const { status, message } = pgErrorToStatus(err);
    logger.error("prospect update failed", { error: err?.message ?? String(err), pg_code: err?.code, prospect_id: id });
    res.status(status).json({ error: message });
  }
});

prospectsRouter.delete("/:id", async (req, res) => {
  const { id } = req.params;
  const { rows } = await pool.query(`DELETE FROM prospects WHERE id = $1 RETURNING id`, [id]);
  if (rows.length === 0) return res.status(404).json({ error: "Prospect not found." });
  res.status(204).send();
});
