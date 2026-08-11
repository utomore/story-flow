import type { FacetValue } from "../api/types";
import type { Query } from "../api/client";

interface Props {
  facets: {
    kinds: FacetValue[];
    vendors: FacetValue[];
    authors: FacetValue[];
    packs: FacetValue[];
  } | null;
  query: Query;
  setQuery: (q: Query) => void;
}

/**
 * facet 側欄。
 *
 * 計數由後端算,而且算某個 facet 時會排除該 facet 自己的條件 ——
 * 否則選了「廠商 = Crusenho」之後,廠商清單只剩 Crusenho 一項,
 * 使用者就沒辦法改選別人。
 */
export function Facets({ facets, query, setQuery }: Props) {
  const toggle = (key: "kinds" | "vendors" | "authors" | "packs", value: string) => {
    const cur = query[key];
    setQuery({
      ...query,
      [key]: cur.includes(value) ? cur.filter((v) => v !== value) : [...cur, value],
    });
  };

  const group = (
    title: string,
    key: "kinds" | "vendors" | "authors" | "packs",
    values: FacetValue[],
    limit = 20,
  ) =>
    values.length > 0 && (
      <div className="facet" key={key}>
        <h3>{title}</h3>
        {values.slice(0, limit).map((f) => (
          <button
            key={f.value}
            className={query[key].includes(f.value) ? "on" : ""}
            onClick={() => toggle(key, f.value)}
          >
            <span>{f.value}</span>
            <span>{f.count}</span>
          </button>
        ))}
      </div>
    );

  return (
    <div className="sidebar">
      <div className="toggles">
        <label>
          <input
            type="checkbox"
            checked={query.named}
            onChange={(e) => setQuery({ ...query, named: e.target.checked })}
          />
          只看已命名
        </label>
        <label>
          <input
            type="checkbox"
            checked={query.reference}
            onChange={(e) => setQuery({ ...query, reference: e.target.checked })}
          />
          納入參考資料
        </label>
        <label>
          <input
            type="checkbox"
            checked={query.excluded}
            onChange={(e) => setQuery({ ...query, excluded: e.target.checked })}
          />
          納入宣傳圖
        </label>
      </div>

      {facets && (
        <>
          {group("類型", "kinds", facets.kinds)}
          {group("廠商", "vendors", facets.vendors)}
          {group("作者", "authors", facets.authors)}
          {group("素材包", "packs", facets.packs, 30)}
        </>
      )}
    </div>
  );
}
