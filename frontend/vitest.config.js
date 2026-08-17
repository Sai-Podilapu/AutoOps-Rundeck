import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";

// Hermetic front-end suite: jsdom, no network, no backend. Every test that
// touches the API stubs global.fetch, the same way the Java suites use an
// in-memory database instead of MySQL.
export default defineConfig({
  plugins: [react()],
  test: {
    environment: "jsdom",
    globals: true,
    setupFiles: ["./src/test/setup.js"],
    include: ["src/**/*.test.{js,jsx}"],
    restoreMocks: true,
    coverage: {
      provider: "v8",
      include: ["src/lib/**", "src/store/**"],
      reporter: ["text-summary"],
    },
  },
});
