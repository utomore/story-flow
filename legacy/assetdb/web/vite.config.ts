import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// 開發時前端跑在 5173,API 在 8787。proxy 讓前端程式碼裡的路徑
// 在開發與正式環境完全相同 —— 不需要條件式的 base URL。
// 8787 與後端 server/src/AssetDB/Server/Cli.hs 的 defaultPort 是同一個
// 埠號,兩邊沒有共用的設定來源 —— 改其中一邊記得同步另一邊(delivery/E002)。
export default defineConfig({
  plugins: [react()],
  server: {
    proxy: {
      "/api": "http://localhost:8787",
      "/thumb": "http://localhost:8787",
    },
  },
  build: { outDir: "dist", emptyOutDir: true },
});
