import { describe, expect, it } from 'vitest';

import { packageName } from './index.js';

describe('@codex-lens/shared', () => {
  it('exports its package name', () => {
    expect(packageName).toBe('@codex-lens/shared');
  });
});
