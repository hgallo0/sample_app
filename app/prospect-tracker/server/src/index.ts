import "dotenv/config";
// Patches Express 4's router so rejected promises in async handlers reach the
// global error handler below instead of hanging the request unhandled - must
// be imported before any Router() is created, including prospectsRouter's.
import "express-async-errors";
import express from "express";
import cors from "cors";
import { pool } from "./db/pool.js";
import { logger } from "./logger.js";
import { syntheticCheckTotal } from "./metrics.js";
import { prospectsRouter } from "./routes/prospects.js";
import { PROSPECT_STAGES } from "./stages.js";

const app = express();
app.use(cors());
app.use(express.json());

app.get("/api/health", async (req, res) => {
  // Set by the Cloud Scheduler synthetic check (infra/main.tf) so its
  // requests are countable as a distinct outside-in signal, separate from
  // real advisor traffic hitting the same route.
  const isSynthetic = req.get("x-synthetic-check") === "true";
  try {
    await pool.query("SELECT 1");
    if (isSynthetic) syntheticCheckTotal.add(1, { result: "ok" });
    res.json({ ok: true });
  } catch (err: any) {
    logger.error("health check failed", { error: err?.message ?? String(err) });
    if (isSynthetic) syntheticCheckTotal.add(1, { result: "error" });
    res.status(503).json({ ok: false, error: "Database unavailable." });
  }
});

app.get("/api/stages", (_req, res) => {
  res.json(PROSPECT_STAGES);
});

app.get("/api/advisors", async (_req, res, next) => {
  try {
    const { rows } = await pool.query("SELECT id, name, email FROM advisors ORDER BY id");
    res.json(rows);
  } catch (err) {
    next(err);
  }
});

app.use("/api/prospects", prospectsRouter);

// Global error handler - catches anything routes pass to next(err) or throw
// from an async handler not already wrapped in try/catch, so failures surface
// as a clean 500 JSON body instead of crashing the process or hanging the request.
app.use((err: any, _req: express.Request, res: express.Response, _next: express.NextFunction) => {
  logger.error("unhandled request error", { error: err?.message ?? String(err) });
  res.status(500).json({ error: "Unexpected server error." });
});

const port = Number(process.env.PORT) || 4000;
app.listen(port, () => {
  console.log(`Server listening on http://localhost:${port}`);
});
