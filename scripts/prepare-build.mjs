import { mkdir, writeFile } from 'node:fs/promises';
import { URL } from 'node:url';

const sharedPackageDirectory = new URL(
  '../dist/node_modules/@codex-lens/shared/',
  import.meta.url,
);

await mkdir(sharedPackageDirectory, { recursive: true });
await Promise.all([
  writeFile(
    new URL('package.json', sharedPackageDirectory),
    `${JSON.stringify(
      {
        name: '@codex-lens/shared',
        private: true,
        type: 'module',
        exports: './index.js',
      },
      null,
      2,
    )}\n`,
  ),
  writeFile(
    new URL('index.js', sharedPackageDirectory),
    "export * from '../../../packages/shared/src/index.js';\n",
  ),
]);
