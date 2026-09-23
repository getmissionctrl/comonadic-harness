import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Dev server on 5173; the harness AG-UI server runs separately on 8080 and is
// reached cross-origin (the server sends permissive CORS on POST /agent).
export default defineConfig({
  plugins: [react()],
  server: { port: 5173 },
});
