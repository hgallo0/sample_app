export const PROSPECT_STAGES = [
  "lead",
  "contacted",
  "meeting_scheduled",
  "proposal_sent",
  "negotiation",
  "client",
  "lost",
] as const;

export type ProspectStage = (typeof PROSPECT_STAGES)[number];

export function isProspectStage(value: unknown): value is ProspectStage {
  return typeof value === "string" && (PROSPECT_STAGES as readonly string[]).includes(value);
}

export const STAGES_REQUIRING_PROPOSAL_FIELDS: ProspectStage[] = ["proposal_sent", "negotiation", "client"];

export const VALID_SERVICE_FEES = [0.2, 0.5];
