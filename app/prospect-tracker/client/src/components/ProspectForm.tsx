import { useState } from "react";
import { PROSPECT_STAGES, STAGE_LABELS, STAGES_REQUIRING_PROPOSAL_FIELDS, VALID_SERVICE_FEES } from "../types";
import type { Prospect, ProspectInput, ProspectStage } from "../types";

interface Props {
  advisorId: number;
  initial?: Prospect;
  onCancel: () => void;
  onSubmit: (input: ProspectInput) => Promise<void>;
  onDelete?: () => Promise<void>;
}

export function ProspectForm({ advisorId, initial, onCancel, onSubmit, onDelete }: Props) {
  const [firstName, setFirstName] = useState(initial?.first_name ?? "");
  const [lastName, setLastName] = useState(initial?.last_name ?? "");
  const [email, setEmail] = useState(initial?.email ?? "");
  const [phone, setPhone] = useState(initial?.phone ?? "");
  const [stage, setStage] = useState<ProspectStage>(initial?.stage ?? "lead");
  const [estimatedValue, setEstimatedValue] = useState(initial?.estimated_value ?? "");
  const [serviceFee, setServiceFee] = useState(initial?.service_fee ?? "");
  const [notes, setNotes] = useState(initial?.notes ?? "");
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  const requiresProposalFields = STAGES_REQUIRING_PROPOSAL_FIELDS.includes(stage);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);

    if (requiresProposalFields && (estimatedValue === "" || serviceFee === "")) {
      setError("Estimated value and service fee are required once a prospect reaches the proposal stage.");
      return;
    }

    setSaving(true);
    try {
      await onSubmit({
        advisor_id: advisorId,
        first_name: firstName,
        last_name: lastName,
        email,
        phone: phone || undefined,
        stage,
        estimated_value: estimatedValue === "" ? undefined : Number(estimatedValue),
        service_fee: serviceFee === "" ? undefined : Number(serviceFee),
        notes: notes || undefined,
      });
    } catch (err) {
      setError(err instanceof Error ? err.message : "Something went wrong.");
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="modal-backdrop" onClick={onCancel}>
      <form className="modal" onClick={(e) => e.stopPropagation()} onSubmit={handleSubmit}>
        <h2>{initial ? "Edit Prospect" : "Add Prospect"}</h2>

        <div className="field-row">
          <label>
            First name
            <input value={firstName} onChange={(e) => setFirstName(e.target.value)} required />
          </label>
          <label>
            Last name
            <input value={lastName} onChange={(e) => setLastName(e.target.value)} required />
          </label>
        </div>

        <label>
          Email
          <input type="email" value={email} onChange={(e) => setEmail(e.target.value)} required />
        </label>

        <div className="field-row">
          <label>
            Phone
            <input value={phone} onChange={(e) => setPhone(e.target.value)} />
          </label>
          <label>
            Estimated value ($){requiresProposalFields && " *"}
            <input
              type="number"
              min="0"
              step="0.01"
              value={estimatedValue}
              onChange={(e) => setEstimatedValue(e.target.value)}
              required={requiresProposalFields}
            />
          </label>
        </div>

        <label>
          Service fee (%){requiresProposalFields && " *"}
          <select
            value={serviceFee}
            onChange={(e) => setServiceFee(e.target.value)}
            required={requiresProposalFields}
          >
            <option value="">Select a fee</option>
            {VALID_SERVICE_FEES.map((fee) => (
              <option key={fee} value={fee}>
                {fee}%
              </option>
            ))}
          </select>
        </label>

        <label>
          Stage
          <select value={stage} onChange={(e) => setStage(e.target.value as ProspectStage)}>
            {PROSPECT_STAGES.map((s) => (
              <option key={s} value={s}>
                {STAGE_LABELS[s]}
              </option>
            ))}
          </select>
        </label>

        <label>
          Notes
          <textarea value={notes} onChange={(e) => setNotes(e.target.value)} rows={3} />
        </label>

        {error && <p className="error">{error}</p>}

        <div className="modal-actions">
          {onDelete && (
            <button
              type="button"
              className="danger"
              disabled={saving}
              onClick={async () => {
                setSaving(true);
                try {
                  await onDelete();
                } catch (err) {
                  setError(err instanceof Error ? err.message : "Delete failed.");
                  setSaving(false);
                }
              }}
            >
              Remove
            </button>
          )}
          <div className="spacer" />
          <button type="button" onClick={onCancel} disabled={saving}>
            Cancel
          </button>
          <button type="submit" className="primary" disabled={saving}>
            {saving ? "Saving..." : "Save"}
          </button>
        </div>
      </form>
    </div>
  );
}
