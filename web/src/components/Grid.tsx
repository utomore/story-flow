import { useVirtualizer } from "@tanstack/react-virtual";
import { useEffect, useRef, useState } from "react";
import { search, thumbUrl, type Query } from "../api/client";
import type { SearchItem } from "../api/types";

const CELL = 132;
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

  // 補抓可視範圍內還沒載入的分頁。
  useEffect(() => {
    const vis = virt.getVirtualItems();
    if (vis.length === 0) return;
    const first = vis[0].index * cols;
    const last = (vis[vis.length - 1].index + 1) * cols;
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
  }, [virt.getVirtualItems(), cols, items, query]);

  return (
    <div ref={scrollRef} className="grid-scroll">
      <div style={{ height: virt.getTotalSize(), position: "relative" }}>
        {virt.getVirtualItems().map((row) => (
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
                    onClick={() => item && onSelect(item)}
                  />
                </div>
              );
            })}
          </div>
        ))}
      </div>
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
    <div className={`card${selected ? " selected" : ""}`} onClick={onClick}>
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
