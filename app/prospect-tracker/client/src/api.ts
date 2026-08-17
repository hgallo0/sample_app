import type { Advisor, Prospect, ProspectInput } from "./types";

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(path, {
    headers: { "Content-Type": "application/json" },
    ...init,
  });
  if (!res.ok) {
    const body = await res.json().catch(() => ({ error: res.statusText }));
    throw new Error(body.error ?? "Request failed");
  }
  if (res.status === 204) return undefined as T;
  return res.json();
}

// wealth.cloudwithgallo.com is this app's own dedicated domain, so /api/* is
// unambiguous here (unlike the shared rps.cloudwithgallo.com domain).
export const api = {
  listProspects: () => request<Prospect[]>("/api/prospects"),
  listAdvisors: () => request<Advisor[]>("/api/advisors"),
  createProspect: (input: ProspectInput) =>
    request<Prospect>("/api/prospects", { method: "POST", body: JSON.stringify(input) }),
  updateProspect: (id: number, input: Partial<ProspectInput>) =>
    request<Prospect>(`/api/prospects/${id}`, { method: "PUT", body: JSON.stringify(input) }),
  deleteProspect: (id: number) => request<void>(`/api/prospects/${id}`, { method: "DELETE" }),
};
