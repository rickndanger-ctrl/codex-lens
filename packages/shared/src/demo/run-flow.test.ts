import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { afterEach, beforeEach, describe, expect, it } from 'vitest';

const repoRoot = fileURLToPath(new URL('../../../..', import.meta.url));

describe('demo run-flow script', () => {
  let dataDirectory: string;

  beforeEach(() => {
    dataDirectory = mkdtempSync(join(tmpdir(), 'codex-lens-demo-test-'));
  });

  afterEach(() => {
    rmSync(dataDirectory, { recursive: true, force: true });
  });

  it('walks the flow to an approved plan and exits 0', () => {
    const stdout = execFileSync('npm', ['run', 'demo', '--silent'], {
      cwd: repoRoot,
      encoding: 'utf8',
      env: { ...process.env, CODEX_LENS_DATA_DIR: dataDirectory },
    });

    expect(stdout).toContain('ConversationSession: Draft -> Clarifying');
    expect(stdout).toContain('ConversationSession: Clarifying -> ReadyForPlan');
    expect(stdout).toContain(
      'ConversationSession: ReadyForPlan -> ConvertedToEngineeringPlan',
    );
    expect(stdout).toContain('EngineeringPlan: Draft -> ReadyForApproval');
    expect(stdout).toContain('EngineeringPlan: ReadyForApproval -> Approved');
    expect(stdout).toMatch(
      /EngineeringPlan Approved \(version=1, digest=[0-9a-f]{64}\)/,
    );
    expect(stdout.trim().endsWith('DEMO COMPLETE')).toBe(true);
  });
});
