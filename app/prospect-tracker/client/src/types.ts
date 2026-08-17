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

export const STAGE_LABELS: Record<ProspectStage, string> = {
  lead: "Lead",
  contacted: "Contacted",
  meeting_scheduled: "Meeting Scheduled",
  proposal_sent: "Proposal Sent",
  negotiation: "Negotiation",
  client: "Client",
  lost: "Lost",
};

export const STAGES_REQUIRING_PROPOSAL_FIELDS: ProspectStage[] = ["proposal_sent", "negotiation", "client"];

export const VALID_SERVICE_FEES = [0.2, 0.5] as const;

export interface Prospect {
  id: number;
  advisor_id: number;
  first_name: string;
  last_name: string;
  email: string;
  phone: string | null;
  stage: ProspectStage;
  estimated_value: string | null;
  service_fee: string | null;
  notes: string | null;
  created_at: string;
  updated_at: string;
}

export interface Advisor {
  id: number;
  name: string;
  email: string;
}

export interface ProspectInput {
  advisor_id: number;
  first_name: string;
  last_name: string;
  email: string;
  phone?: string;
  stage?: ProspectStage;
  estimated_value?: number;
  service_fee?: number;
  notes?: string;
}
