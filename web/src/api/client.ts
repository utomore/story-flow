import type { Facets, Health, PackSummary, SearchResponse } from "./types";

// 查詢條件。與後端的 query string 一一對應。
export interface Query {
  q: string;
  kinds: string[];
  packs: string[];
  vendors: string[];
  authors: string[];
  named: boolean;
  reference: boolean;
  excluded: boolean;
}

export const emptyQuery: Query = {
  q: "",
  kinds: [],
  packs: [],
  vendors: [],
  authors: [],
  named: false,
  reference: false,
  excluded: false,
};

function params(query: Query, extra: Record<string, string> = {}): string {
  const p = new URLSearchParams();
  if (query.q.trim()) p.set("q", query.q.trim());
  for (const k of query.kinds) p.append("kind", k);
  for (const k of query.packs) p.append("pack", k);
  for (const k of query.vendors) p.append("vendor", k);
  for (const k of query.authors) p.append("author", k);
  // servant 的 QueryFlag 認的是「參數存在與否」,不是值。
  if (query.named) p.set("named", "");
  if (query.reference) p.set("reference", "");
  if (query.excluded) p.set("excluded", "");
  for (const [k, v] of Object.entries(extra)) p.set(k, v);
  return p.toString();
}

async function getJson<T>(url: string, signal?: AbortSignal): Promise<T> {
  const r = await fetch(url, { signal });
  if (!r.ok) throw new Error(`${r.status} ${r.statusText}`);
  return (await r.json()) as T;
}

export function search(
  query: Query,
  limit: number,
  offset: number,
  signal?: AbortSignal,
): Promise<SearchResponse> {
  return getJson(
    `/api/search?${params(query, { limit: String(limit), offset: String(offset) })}`,
    signal,
  );
}

export function facets(query: Query, signal?: AbortSignal): Promise<Facets> {
  return getJson(`/api/facets?${params(query)}`, signal);
}

export const health = (): Promise<Health> => getJson("/api/health");
export const packs = (): Promise<PackSummary[]> => getJson("/api/packs");

export const thumbUrl = (sha: string | null, size: 128 | 512): string | null =>
  sha ? `/thumb/${sha}/${size}` : null;
