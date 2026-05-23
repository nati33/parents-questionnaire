import { defineConfig } from 'vite';
import { resolve } from 'path';

// Multi-page setup — each HTML in public/ is its own entry.
// During dev (npm run dev), Vite serves from public/.
// Build output goes to dist/ at repo root.
export default defineConfig({
  root: 'public',
  publicDir: false,
  build: {
    outDir: '../dist',
    emptyOutDir: true,
    rollupOptions: {
      input: {
        main:   resolve(__dirname, 'public/index.html'),
        review: resolve(__dirname, 'public/review.html'),
        form:   resolve(__dirname, 'public/form.html'),
        invite: resolve(__dirname, 'public/invite.html'),
      },
    },
  },
});
