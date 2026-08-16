import { useEffect } from "react";
import { createPortal } from "react-dom";
import { thumbUrl } from "../api/client";
import type { SearchItem } from "../api/types";

interface Props {
  item: SearchItem | undefined;
  hasPrev: boolean;
  hasNext: boolean;
  onPrev: () => void;
  onNext: () => void;
  onClose: () => void;
}

/**
 * 放大檢視。
 *
 * 說明**放在大圖正下方**,不是側邊也不是頁尾 —— 看圖與讀說明是同一個動作,
 * 中間隔著任何東西都會逼使用者的視線來回跑。
 *
 * 用 portal 掛在 document.body 而不是留在 React 樹裡:.app 是 100vh 且
 * overflow:hidden 的 grid,任何留在裡面的絕對定位元素都會被裁掉。
 */
export function Lightbox({ item, hasPrev, hasNext, onPrev, onNext, onClose }: Props) {
  // 鍵盤綁在 window 上。彈窗本身要不要有焦點是另一回事 ——
  // 使用者剛剛在點縮圖,焦點還在網格裡,這時候按 Esc 一樣要能關掉。
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
      else if (e.key === "ArrowLeft" && hasPrev) onPrev();
      else if (e.key === "ArrowRight" && hasNext) onNext();
      else return;
      e.preventDefault();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [hasPrev, hasNext, onPrev, onNext, onClose]);

  const src = item ? thumbUrl(item.sha, 512) : null;

  return createPortal(
    <div className="lb-backdrop" onClick={onClose}>
      {/* 停止冒泡,否則點在面板上也會關掉。 */}
      <div className="lb" onClick={(e) => e.stopPropagation()}>
        <button className="lb-close" onClick={onClose} title="關閉 (Esc)" aria-label="關閉">
          ✕
        </button>

        <button className="lb-nav prev" onClick={onPrev} disabled={!hasPrev} title="上一筆 (←)">
          ‹
        </button>
        <button className="lb-nav next" onClick={onNext} disabled={!hasNext} title="下一筆 (→)">
          ›
        </button>

        <div className="lb-stage">
          {src ? (
            <img src={src} alt={item?.name ?? item?.original ?? ""} />
          ) : (
            <div className="lb-nothumb">{item ? "這份內容沒有縮圖" : "載入中…"}</div>
          )}
        </div>

        {item && (
          <div className="lb-info">
            <div className="lb-title">{item.name ?? <em>未命名</em>}</div>
            <dl>
              <dt>原始檔名</dt>
              <dd>{item.original}</dd>
              <dt>類型</dt>
              <dd>{item.kind}</dd>
              <dt>素材包</dt>
              <dd>
                {item.pack ?? "—"}
                {item.author ? <span className="dim">{`  ·  ${item.author}`}</span> : null}
              </dd>
              <dt>路徑</dt>
              <dd className="mono">{item.path}</dd>
              <dt>內容雜湊</dt>
              <dd className="mono">{item.sha ?? "—"}</dd>
            </dl>
          </div>
        )}
      </div>
    </div>,
    document.body,
  );
}
