import { useVirtualizer } from "@tanstack/react-virtual";
import { useEffect, useRef, useState } from "react";
import { search, thumbUrl, type Query } from "../api/client";
import type { SearchItem } from "../api/types";
import { Lightbox } from "./Lightbox";

const CELL = 132;
// 一頁 120 筆,約數多(cols 常見 4-8 都整除),一次涵蓋數個可視畫面。
// 各入口的分頁預設刻意不同,不是漏改(G-E001):server 預設 60 /
// 上限 500(Server/App.hs)、CLI 預設 20(Cli/Options.hs)、store 層
// 函式庫預設 50(Store/Search.hs)。
const PAGE = 120;

interface Props {
  query: Query;
  onSelect: (item: SearchItem | null) => void;
  selected: SearchItem | null;
  onTotal: (n: number) => void;
}

/**
 * 虛擬化網格。
 *
 * 六千筆縮圖不可能全部掛進 DOM,所以只渲染可視範圍。分頁是**依需求載入**:
 * 捲到哪裡才抓那一段,而不是一次抓完 —— 後者會讓第一次顯示等上好幾秒。
 *
 * 格子是固定尺寸的正方形。縮圖產生時就已經統一成正方形畫布,
 * 就是為了讓這裡的高度計算不需要等圖片載入。
 */
export function Grid({ query, onSelect, selected, onTotal }: Props) {
  const scrollRef = useRef<HTMLDivElement>(null);
  const [total, setTotal] = useState(0);
  const [items, setItems] = useState<(SearchItem | undefined)[]>([]);
  const [cols, setCols] = useState(6);
  const pending = useRef(new Set<number>());
  // 放大檢視的位置。用索引而不是 SearchItem,前後筆才有意義 ——
  // 而 items 就在這裡,沒必要把整份清單提到 App 去。
  const [openIdx, setOpenIdx] = useState<number | null>(null);

  // 欄數隨容器寬度變。放在 effect 裡而不是 CSS grid,是因為虛擬化需要
  // 明確知道每列有幾個才能算出總列數。
  useEffect(() => {
    const el = scrollRef.current;
    if (!el) return;
    const ro = new ResizeObserver(() => {
      setCols(Math.max(1, Math.floor((el.clientWidth - 24) / CELL)));
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  // 查詢改變就重置。不保留舊資料 —— 顯示上一次查詢的結果比空白更糟。
  useEffect(() => {
    const ac = new AbortController();
    pending.current.clear();
    // 換查詢就關掉放大檢視。索引指向的是舊結果集,留著會顯示不相干的東西。
    setOpenIdx(null);
    search(query, PAGE, 0, ac.signal)
      .then((r) => {
        const next: (SearchItem | undefined)[] = new Array(r.total);
        r.items.forEach((it, i) => (next[i] = it));
        setTotal(r.total);
        setItems(next);
        onTotal(r.total);
        scrollRef.current?.scrollTo({ top: 0 });
      })
      .catch((e) => {
        if (e.name !== "AbortError") console.error(e);
      });
    return () => ac.abort();
  }, [query, onTotal]);

  const rows = Math.ceil(total / cols);
  const virt = useVirtualizer({
    count: rows,
    getScrollElement: () => scrollRef.current,
    estimateSize: () => CELL,
    overscan: 4,
  });

  // 可視列區間。effect 依賴的是這兩個穩定的衍生值,而不是
  // getVirtualItems() 的回傳值 —— 那每次呼叫都是新的陣列參照,
  // 放進依賴陣列會讓 effect 每次渲染都重跑。
  const vis = virt.getVirtualItems();
  const firstRow = vis.length > 0 ? vis[0].index : -1;
  const lastRow = vis.length > 0 ? vis[vis.length - 1].index : -1;

  // 補抓可視範圍內還沒載入的分頁。
  useEffect(() => {
    if (firstRow < 0) return;
    const first = firstRow * cols;
    const last = (lastRow + 1) * cols;
    for (let off = Math.floor(first / PAGE) * PAGE; off < last; off += PAGE) {
      if (items[off] !== undefined || pending.current.has(off)) continue;
      pending.current.add(off);
      search(query, PAGE, off)
        .then((r) => {
          setItems((prev) => {
            const next = prev.slice();
            r.items.forEach((it, i) => (next[off + i] = it));
            return next;
          });
        })
        .catch(console.error)
        .finally(() => pending.current.delete(off));
    }
  }, [firstRow, lastRow, cols, items, query]);

  // 放大檢視用 ←/→ 可以走到可視範圍之外,而上面那個 effect 只補「看得到」的分頁。
  // 沒有這段的話,連按方向鍵就會停在一個永遠是「載入中…」的空格上。
  useEffect(() => {
    if (openIdx === null || items[openIdx] !== undefined) return;
    const off = Math.floor(openIdx / PAGE) * PAGE;
    if (pending.current.has(off)) return;
    pending.current.add(off);
    search(query, PAGE, off)
      .then((r) => {
        setItems((prev) => {
          const next = prev.slice();
          r.items.forEach((it, i) => (next[off + i] = it));
          return next;
        });
      })
      .catch(console.error)
      .finally(() => pending.current.delete(off));
  }, [openIdx, items, query]);

  // 放大檢視翻頁時,底下的選取跟著走 —— 關掉彈窗後停在哪裡不該是個謎。
  useEffect(() => {
    if (openIdx === null) return;
    const it = items[openIdx];
    if (it) onSelect(it);
  }, [openIdx, items, onSelect]);

  return (
    <div ref={scrollRef} className="grid-scroll">
      <div style={{ height: virt.getTotalSize(), position: "relative" }}>
        {vis.map((row) => (
          <div key={row.key}>
            {Array.from({ length: cols }, (_, c) => {
              const i = row.index * cols + c;
              if (i >= total) return null;
              const item = items[i];
              return (
                <div
                  key={i}
                  className="cell"
                  style={{
                    transform: `translateY(${row.start}px)`,
                    left: c * CELL,
                    width: CELL,
                    height: CELL,
                  }}
                >
                  <Card
                    item={item}
                    selected={!!item && selected?.ulid === item.ulid}
                    onClick={() => {
                      if (!item) return;
                      onSelect(item);
                      setOpenIdx(i);
                    }}
                  />
                </div>
              );
            })}
          </div>
        ))}
      </div>

      {openIdx !== null && (
        <Lightbox
          item={items[openIdx]}
          hasPrev={openIdx > 0}
          hasNext={openIdx < total - 1}
          onPrev={() => setOpenIdx((i) => (i === null ? i : Math.max(0, i - 1)))}
          onNext={() => setOpenIdx((i) => (i === null ? i : Math.min(total - 1, i + 1)))}
          onClose={() => setOpenIdx(null)}
        />
      )}
    </div>
  );
}

function Card({
  item,
  selected,
  onClick,
}: {
  item: SearchItem | undefined;
  selected: boolean;
  onClick: () => void;
}) {
  if (!item) return <div className="card" />;
  const src = thumbUrl(item.sha, 128);
  return (
    <div
      className={`card${selected ? " selected" : ""}`}
      onClick={onClick}
      // 格子本來是純 div,鍵盤完全到不了。給它 button 語意,
      // 六千張圖至少變成可以用 Tab + Enter 走完的東西。
      role="button"
      tabIndex={0}
      onKeyDown={(e) => {
        if (e.key === "Enter" || e.key === " ") {
          e.preventDefault();
          onClick();
        }
      }}
    >
      {src ? (
        <img src={src} alt={item.name ?? item.original} loading="lazy" />
      ) : (
        <div style={{ flex: 1 }} />
      )}
      <div className={`label${item.name ? " named" : ""}`} title={item.name ?? item.original}>
        {item.name ?? item.original}
      </div>
    </div>
  );
}
