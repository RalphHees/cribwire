import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    include: ['test/**/*.test.ts'],
    environment: 'node',
    // Integration tests talk to a shared Postgres/Redis; keep files sequential
    // so migrations and truncations do not race each other.
    fileParallelism: false,
    testTimeout: 15_000,
  },
});
