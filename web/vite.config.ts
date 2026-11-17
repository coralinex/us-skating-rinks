import { defineConfig } from 'vite';

export default defineConfig({
  // Relative asset URLs, so the same build works at a domain root and under a
  // sub-path such as https://<user>.github.io/<repo>/.
  base: './',
  build: {
    // MapLibre is one large chunk; that is expected.
    chunkSizeWarningLimit: 2500,
  },
});
