import { useEffect, useMemo, useState } from "react";
import { packs as fetchPacks, type Query } from "../api/client";
import type { FacetValue, PackSummary } from "../api/types";

type GroupKey = "categories" | "kinds" | "packs" | "authors" | "vendors";

const LABEL: Record<GroupKey, string> = {
  categories: "分類",
  kinds: "類型",
  packs: "素材包",
  authors: "作者",
  vendors: "廠商",
};

/** 一開始就展開的分組。其餘收合 —— 六千筆素材的側欄一次攤開就沒人看得完。 */
const OPEN_BY_DEFAULT: GroupKey[] = ["categories", "kinds"];

/**
 * 分類是階層式的,而後端依計數排序 —— 直接照抄那個順序會讓 fx\/magic
 * 排在 gui 前面,兩層混在一起沒人讀得懂。這裡重排成「頂層依計數,子分類
 * 跟在自己的父分類底下」。
 */
function nestCategories(values: FacetValue[]): { f: FacetValue; child: boolean }[] {
  const tops = values.filter((v) => !v.value.includes("/"));
  const kids = values.filter((v) => v.value.includes("/"));
  const out: { f: FacetValue; child: boolean }[] = [];
  for (const t of tops) {
    out.push({ f: t, child: false });
    for (const k of kids.filter((k) => k.value.startsWith(t.value + "/"))) {
      out.push({ f: k, child: true });
    }
  }
  // 父分類不在結果集裡的孤兒也要顯示,否則會靜靜消失。
  for (const k of kids) {
    if (!tops.some((t) => k.value.startsWith(t.value + "/"))) out.push({ f: k, child: true });
  }
  return out;
}

interface Props {
  facets: Record<GroupKey, FacetValue[]> | null;
  query: Query;
  setQuery: (q: Query) => void;
}

/**
 * facet 側欄。
 *
 * 兩個設計前提:
 *
 * 1. **已選條件放最上面。** 條件散在各分組裡時,使用者要捲完整欄才知道
 *    自己現在在看什麼子集合 —— 而「我剛剛選了什麼」是比「還能選什麼」
 *    更急迫的問題。
 *
 * 2. **廠商與作者預設合併。** 實際資料裡 6 組有 4 組完全同名
 *    (BDragon1727、Kibyra…),只有 Crusenho → Crusenho Agus Hennihuno
 *    與 shikashipx → Matt Firth 不同。並列兩欄近乎重複的清單是純粹的浪費。
 *    但這是**資料決定的**,不是寫死的:只要出現一個廠商底下有多位作者,
 *    廠商就重新變成有意義的獨立軸,那一組就會自己冒出來(見 vendorIsDistinct)。
 *
 * 計數由後端算,而且算某個 facet 時會排除該 facet 自己的條件 ——
 * 否則選了「作者 = Crusenho」之後,作者清單只剩他一個,就改不了選擇。
 */
export function Facets({ facets, query, setQuery }: Props) {
  const [open, setOpen] = useState<Record<string, boolean>>(() =>
    Object.fromEntries(OPEN_BY_DEFAULT.map((k) => [k, true])),
  );
  const [packRows, setPackRows] = useState<PackSummary[]>([]);

  // 只抓一次。這份資料是用來把廠商名接到作者名上的,與查詢條件無關。
  useEffect(() => {
    fetchPacks().then(setPackRows).catch(console.error);
  }, []);

  const { vendorOf, vendorIsDistinct } = useMemo(() => {
    const vOf = new Map<string, string>();
    const authorsPerVendor = new Map<string, Set<string>>();
    for (const p of packRows) {
      if (!p.author || !p.vendor) continue;
      vOf.set(p.author, p.vendor);
      const s = authorsPerVendor.get(p.vendor) ?? new Set<string>();
      s.add(p.author);
      authorsPerVendor.set(p.vendor, s);
    }
    // 一個廠商底下有兩位以上作者時,廠商才是獨立的篩選軸。
    const distinct = [...authorsPerVendor.values()].some((s) => s.size > 1);
    return { vendorOf: vOf, vendorIsDistinct: distinct };
  }, [packRows]);

  const toggle = (key: GroupKey, value: string) => {
    const cur = query[key];
    setQuery({
      ...query,
      [key]: cur.includes(value) ? cur.filter((v) => v !== value) : [...cur, value],
    });
  };

  const clearAll = () =>
    setQuery({ ...query, categories: [], kinds: [], packs: [], authors: [], vendors: [] });

  // ── 已選條件 ────────────────────────────────────────────────
  const chips: { key: GroupKey; value: string; label: string }[] = [];
  for (const key of ["categories", "kinds", "authors", "vendors", "packs"] as GroupKey[]) {
    for (const v of query[key]) chips.push({ key, value: v, label: `${LABEL[key]}：${v}` });
  }

  const groupKeys: GroupKey[] = vendorIsDistinct
    ? ["categories", "kinds", "authors", "vendors", "packs"]
    : ["categories", "kinds", "authors", "packs"];

  return (
    <div className="sidebar">
      {chips.length > 0 && (
        <div className="chosen">
          <div className="chosen-head">
            <h3>已選條件</h3>
            <button className="linkish" onClick={clearAll}>
              清除全部
            </button>
          </div>
          <div className="chips">
            {chips.map((c) => (
              <button
                key={`${c.key}:${c.value}`}
                className="chip"
                onClick={() => toggle(c.key, c.value)}
                title="移除這個條件"
              >
                <span>{c.label}</span>
                <span className="chip-x">✕</span>
              </button>
            ))}
          </div>
        </div>
      )}

      {groupKeys.map((key) => {
        const values = facets?.[key] ?? [];
        if (values.length === 0) return null;
        const isOpen = open[key] ?? false;
        const picked = query[key].length;
        return (
          <div className="facet" key={key}>
            <button
              className="facet-head"
              aria-expanded={isOpen}
              onClick={() => setOpen((o) => ({ ...o, [key]: !isOpen }))}
            >
              <span className={`caret${isOpen ? " open" : ""}`}>▸</span>
              <h3>{key === "authors" && !vendorIsDistinct ? "作者 / 廠商" : LABEL[key]}</h3>
              {picked > 0 && <span className="badge">{picked}</span>}
              <span className="facet-count">{values.length}</span>
            </button>

            {isOpen && (
              <div className="facet-body">
                {key === "categories"
                  ? nestCategories(values).map(({ f, child }) => (
                      <button
                        key={f.value}
                        className={`${query[key].includes(f.value) ? "on" : ""}${child ? " sub" : ""}`}
                        onClick={() => toggle(key, f.value)}
                        title={f.value}
                      >
                        {/* 子分類只顯示葉節點名稱,父層由縮排表達 ——
                            「icon / icon/potion / icon/food」讀起來全是雜訊。 */}
                        <span className="fv">{child ? f.value.split("/").slice(1).join("/") : f.value}</span>
                        <span>{f.count.toLocaleString()}</span>
                      </button>
                    ))
                  : values.slice(0, 30).map((f) => {
                      const vendor = key === "authors" ? vendorOf.get(f.value) : undefined;
                      return (
                        <button
                          key={f.value}
                          className={query[key].includes(f.value) ? "on" : ""}
                          onClick={() => toggle(key, f.value)}
                          title={f.value}
                        >
                          <span className="fv">
                            {f.value}
                            {vendor && vendor !== f.value && <span className="dim">（{vendor}）</span>}
                          </span>
                          <span>{f.count.toLocaleString()}</span>
                        </button>
                      );
                    })}
                {key !== "categories" && values.length > 30 && (
                  <div className="facet-more">還有 {values.length - 30} 項未顯示</div>
                )}
              </div>
            )}
          </div>
        );
      })}

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
    </div>
  );
}
