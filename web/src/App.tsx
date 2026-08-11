import { useEffect, useMemo, useState } from "react";
import { emptyQuery, facets as fetchFacets, health as fetchHealth, type Query } from "./api/client";
import type { Facets as FacetsData, Health, SearchItem } from "./api/types";
import { Detail } from "./components/Detail";
import { Facets } from "./components/Facets";
import { Grid } from "./components/Grid";

export function App() {
  const [raw, setRaw] = useState("");
  const [query, setQuery] = useState<Query>(emptyQuery);
  const [facets, setFacets] = useState<FacetsData | null>(null);
  const [selected, setSelected] = useState<SearchItem | null>(null);
  const [total, setTotal] = useState(0);
  const [health, setHealth] = useState<Health | null>(null);

  useEffect(() => {
    fetchHealth().then(setHealth).catch(console.error);
  }, []);

  // 打字時去抖。每個按鍵都打一次 API 會讓六千筆的查詢排隊塞住。
  useEffect(() => {
    const t = setTimeout(() => setQuery((q) => ({ ...q, q: raw })), 200);
    return () => clearTimeout(t);
  }, [raw]);

  useEffect(() => {
    const ac = new AbortController();
    fetchFacets(query, ac.signal)
      .then(setFacets)
      .catch((e) => e.name !== "AbortError" && console.error(e));
    return () => ac.abort();
  }, [query]);

  const onTotal = useMemo(() => (n: number) => setTotal(n), []);

  return (
    <div className="app">
      <Facets facets={facets} query={query} setQuery={setQuery} />
      <div className="main">
        {health?.indexStale && (
          <div className="warn">全文索引與資源表筆數不符,結果可能不完整。執行 assetdb index 重建。</div>
        )}
        <div className="topbar">
          <input
            className="search"
            placeholder="搜尋素材…(中英文皆可,支援子字串)"
            value={raw}
            onChange={(e) => setRaw(e.target.value)}
            autoFocus
          />
          <div className="count">
            {total.toLocaleString()} 筆
            {health && ` / 共 ${health.assets.toLocaleString()}`}
          </div>
        </div>
        <Grid query={query} onSelect={setSelected} selected={selected} onTotal={onTotal} />
        {selected && <Detail item={selected} />}
      </div>
    </div>
  );
}
