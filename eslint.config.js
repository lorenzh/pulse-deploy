import base from "@lorenzh/pulse-config/eslint.config.js";

// ESLint picks the nearest config per file; keep the read-only clones in `.repos/` and the build output out.
export default [{ ignores: [".repos/**", "dist/**"] }, ...base];
