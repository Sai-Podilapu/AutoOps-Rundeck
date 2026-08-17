import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// In dev, the frontend talks to the Spring Boot auth-service via a proxy so
// that requests to /api are forwarded to http://localhost:8081 (no CORS issues).
// Override the backend target with VITE_PROXY_TARGET if needed.
// Default: the API gateway (which fronts auth-service + subscription-service).
const target = process.env.VITE_PROXY_TARGET || "http://localhost:8080";

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      "/api": {
        target,
        changeOrigin: true,
      },
    },
  },
});
