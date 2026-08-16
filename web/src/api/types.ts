// 由 assetdb-server 產生,請勿手動編輯。
// 重新產生:cabal run assetdb-server -- --emit-types web/src/api/types.ts

export interface SearchItem {
  ulid: string;
  name: string | null;
  original: string;
  kind: string;
  pack: string | null;
  author: string | null;
  path: string;
  sha: string | null;
}

export interface SearchResponse {
  total: number;
  items: SearchItem[];
}

export interface FacetValue {
  value: string;
  count: number;
}

export interface Facets {
  kinds: FacetValue[];
  vendors: FacetValue[];
  authors: FacetValue[];
  packs: FacetValue[];
  categories: FacetValue[];
}

export interface PackSummary {
  slug: string;
  name: string;
  vendor: string | null;
  author: string | null;
  license: string | null;
  status: string;
  ai: string;
  count: number;
}

export interface Health {
  assets: number;
  packs: number;
  named: number;
  thumbs: number;
  indexStale: boolean;
}

