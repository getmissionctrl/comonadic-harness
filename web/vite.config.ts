import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Dev/preview server on 5173; the harness AG-UI server runs separately and is
// reached cross-origin (the server sends permissive CORS on POST /agent).
// host:true binds 0.0.0.0 and allowedHosts lets it be reached by hostname
// (e.g. scape:5173) from another machine, not just localhost.
const shared = { port: 5173, host: true, allowedHosts: true as const };

export default defineConfig({
  plugins: [react()],
  server: shared,
  preview: shared,
});
