import { thumbUrl } from "../api/client";
import type { SearchItem } from "../api/types";

/** 選中素材的細節。512px 縮圖讓像素圖看得清楚。 */
export function Detail({ item }: { item: SearchItem }) {
  const src = thumbUrl(item.sha, 512);
  return (
    <div className="detail">
      {src ? <img src={src} alt={item.name ?? item.original} /> : <div />}
      <dl>
        <dt>名稱</dt>
        <dd>{item.name ?? <em>未命名</em>}</dd>
        <dt>原始檔名</dt>
        <dd>{item.original}</dd>
        <dt>素材包</dt>
        <dd>
          {item.pack ?? "—"}
          {item.author ? `  ·  ${item.author}` : ""}
        </dd>
        <dt>路徑</dt>
        <dd>{item.path}</dd>
        <dt>內容雜湊</dt>
        <dd>{item.sha ? item.sha.slice(0, 16) : "—"}</dd>
      </dl>
    </div>
  );
}
