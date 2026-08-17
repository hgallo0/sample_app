import { useEffect, useMemo, useState } from "react";
import { api } from "./api";
import { ProspectForm } from "./components/ProspectForm";
import { PROSPECT_STAGES, STAGE_LABELS } from "./types";
import type { Advisor, Prospect, ProspectInput } from "./types";
import "./App.css";

export default function App() {
  const [prospects, setProspects] = useState<Prospect[]>([]);
  const [advisor, setAdvisor] = useState<Advisor | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [editing, setEditing] = useState<Prospect | null>(null);
  const [adding, setAdding] = useState(false);

  async function refresh() {
    setLoading(true);
    try {
      const [prospectList, advisors] = await Promise.all([api.listProspects(), api.listAdvisors()]);
      setProspects(prospectList);
      setAdvisor(advisors[0] ?? null);
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to load data.");
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    refresh();
  }, []);

  const byStage = useMemo(() => {
    const grouped = new Map<string, Prospect[]>();
    for (const stage of PROSPECT_STAGES) grouped.set(stage, []);
    for (const p of prospects) grouped.get(p.stage)?.push(p);
    return grouped;
  }, [prospects]);

  async function handleCreate(input: ProspectInput) {
    const created = await api.createProspect(input);
    setProspects((prev) => [created, ...prev]);
    setAdding(false);
  }

  async function handleUpdate(id: number, input: ProspectInput) {
    const updated = await api.updateProspect(id, input);
    setProspects((prev) => prev.map((p) => (p.id === id ? updated : p)));
    setEditing(null);
  }

  async function handleDelete(id: number) {
    await api.deleteProspect(id);
    setProspects((prev) => prev.filter((p) => p.id !== id));
    setEditing(null);
  }

  return (
    <div className="app">
      <header className="app-header">
        <div>
          <h1>Prospect Pipeline</h1>
          {advisor && <p className="subtitle">Advisor: {advisor.name}</p>}
        </div>
        <button className="primary" onClick={() => setAdding(true)} disabled={!advisor}>
          + Add Prospect
        </button>
      </header>

      {error && <p className="error banner">{error}</p>}
      {loading && <p className="banner">Loading...</p>}

      <div className="board">
        {PROSPECT_STAGES.map((stage) => (
          <div className="column" key={stage}>
            <div className="column-header">
              <span>{STAGE_LABELS[stage]}</span>
              <span className="count">{byStage.get(stage)?.length ?? 0}</span>
            </div>
            <div className="column-body">
              {byStage.get(stage)?.map((p) => (
                <button key={p.id} className="card" onClick={() => setEditing(p)}>
                  <div className="card-name">
                    {p.first_name} {p.last_name}
                  </div>
                  <div className="card-email">{p.email}</div>
                  {p.estimated_value && (
                    <div className="card-value">
                      ${Number(p.estimated_value).toLocaleString()}
                    </div>
                  )}
                </button>
              ))}
            </div>
          </div>
        ))}
      </div>

      {adding && advisor && (
        <ProspectForm advisorId={advisor.id} onCancel={() => setAdding(false)} onSubmit={handleCreate} />
      )}

      {editing && advisor && (
        <ProspectForm
          advisorId={advisor.id}
          initial={editing}
          onCancel={() => setEditing(null)}
          onSubmit={(input) => handleUpdate(editing.id, input)}
          onDelete={() => handleDelete(editing.id)}
        />
      )}
    </div>
  );
}
