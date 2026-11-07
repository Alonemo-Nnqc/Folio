import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// The build lands in the desktop project; WebView2 serves it from a virtual host, so paths stay relative.
export default defineConfig({
  plugins: [react()],
  base: "./",
  build: { outDir: "../src/Folio.Desktop/wwwroot", emptyOutDir: true, target: "chrome120", chunkSizeWarningLimit: 1500, assetsInlineLimit: 0 },
  server: { port: 5199, strictPort: true },
});
