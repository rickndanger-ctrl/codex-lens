import { mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import {
  executionPlanSchema,
  parseExecutionPlan,
  toJSON,
  type ExecutionPlan,
} from '@codex-lens/shared';
import { afterEach, describe, expect, it } from 'vitest';

import {
  generateExecutionPlan,
  SAMPLE_REPO_TEST_COMMAND,
  type ExecutionPlanRequest,
} from '../src/plan-generation.js';
import {
  CODEX_LENS_REPO_ID,
  CODEX_LENS_REPO_ROOT,
  SAMPLE_REPO_ID,
  SAMPLE_REPO_ROOT,
} from '../src/registryConfig.js';

const canonicalSampleRoot = realpathSync.native(SAMPLE_REPO_ROOT);

const request: ExecutionPlanRequest = {
  text: 'Fix add() in the calculator so it returns the sum instead of the difference.',
  engineeringPlanId: 'engineering-plan-151',
  filesToModify: ['src/calculator.js'],
};

/** Paths created inside the sample repo by a test, removed afterwards. */
const litter: string[] = [];

function inSampleRepo(...segments: string[]): string {
  const created = path.join(canonicalSampleRoot, ...segments);
  litter.push(created);
  return created;
}

afterEach(() => {
  while (litter.length > 0) {
    rmSync(litter.pop() as string, { force: true, recursive: true });
  }
});

function generateOrThrow(override: Partial<ExecutionPlanRequest> = {}): ExecutionPlan {
  const result = generateExecutionPlan({ ...request, ...override }, SAMPLE_REPO_ID);
  if (!result.ok) {
    throw new Error(`expected a plan, got ${result.error.code}: ${result.error.message}`);
  }
  return result.value;
}

describe('generateExecutionPlan', () => {
  it('produces a plan that validates against the shared execution plan schema', () => {
    const plan = generateOrThrow();

    expect(executionPlanSchema.safeParse(plan).success).toBe(true);
    expect(plan.engineeringPlanId).toBe('engineering-plan-151');
    expect(plan.executionStatus).toBe('Pending');
    expect(plan.version).toBe(1);
  });

  it('computes a content digest that re-verifies when the plan is parsed back', () => {
    const plan = generateOrThrow();

    const reparsed = parseExecutionPlan(JSON.parse(JSON.stringify(toJSON(plan))));

    expect(reparsed.ok).toBe(true);
    if (reparsed.ok) {
      expect(reparsed.value.contentDigest).toBe(plan.contentDigest);
    }
  });

  it('rejects a plan whose digest no longer matches its content', () => {
    const plan = generateOrThrow();

    const tampered = parseExecutionPlan({
      ...toJSON(plan),
      estimatedRisk: plan.estimatedRisk === 'High' ? 'Low' : 'High',
    });

    expect(tampered.ok).toBe(false);
    if (!tampered.ok) {
      expect(tampered.error.code).toBe('EXECUTION_PLAN_DIGEST_MISMATCH');
    }
  });

  it('resolves every file it names inside the registered sample repo', () => {
    const plan = generateOrThrow({
      filesToModify: ['src/calculator.js'],
      filesToCreate: ['src/subtract.js'],
      filesToDelete: ['README.md'],
    });

    const files = [
      ...plan.filesToModify,
      ...plan.filesToCreate,
      ...plan.filesToDelete,
    ];

    expect(files).toHaveLength(3);
    for (const file of files) {
      expect(path.isAbsolute(file)).toBe(true);
      expect(file.startsWith(`${canonicalSampleRoot}${path.sep}`)).toBe(true);
    }
    expect(plan.filesToModify).toEqual([
      path.join(canonicalSampleRoot, 'src/calculator.js'),
    ]);
  });

  it("expects the fixture's test command", () => {
    expect(generateOrThrow().expectedCommands).toEqual([SAMPLE_REPO_TEST_COMMAND]);
    expect(SAMPLE_REPO_TEST_COMMAND).toBe('npm test');
  });

  it('estimates risk, complexity and duration for the requested change', () => {
    const oneFile = generateOrThrow();
    expect(oneFile.estimatedRisk).toBe('Low');
    expect(oneFile.estimatedComplexity).toBe('Low');
    expect(oneFile.estimatedDuration).toBeGreaterThan(0);

    const withDeletion = generateOrThrow({ filesToDelete: ['README.md'] });
    expect(withDeletion.estimatedRisk).toBe('High');
    expect(withDeletion.estimatedComplexity).toBe('Medium');
    expect(withDeletion.estimatedDuration).toBeGreaterThan(oneFile.estimatedDuration);
  });

  it('walks the requested change through steps that bracket it with test runs', () => {
    const steps = generateOrThrow().implementationSteps;

    expect(steps[0]).toContain('Fix add()');
    expect(steps[1]).toContain(SAMPLE_REPO_TEST_COMMAND);
    expect(steps.at(-1)).toContain(SAMPLE_REPO_TEST_COMMAND);
    expect(steps.some((step) => step.includes('src/calculator.js'))).toBe(true);
  });
});

describe('generateExecutionPlan rollback strategy', () => {
  it('scopes rollback to the plan files and never restores the whole tree', () => {
    const plan = generateOrThrow({
      filesToModify: ['src/calculator.js'],
      filesToCreate: ['src/subtract.js'],
      filesToDelete: ['README.md'],
    });

    const { rollbackStrategy } = plan;
    expect(rollbackStrategy).not.toContain('git restore .');
    expect(rollbackStrategy).not.toMatch(/git\s+(restore|checkout)\s+[.*]/);

    // Every path the strategy names is quoted, so the quoted tokens are
    // exactly the files this plan is allowed to touch.
    const named = [...rollbackStrategy.matchAll(/'([^']+)'/g)].map((m) => m[1]);
    const planFiles = [
      ...plan.filesToModify,
      ...plan.filesToCreate,
      ...plan.filesToDelete,
    ];
    expect(new Set(named)).toEqual(new Set(planFiles));

    for (const file of [...plan.filesToModify, ...plan.filesToDelete]) {
      expect(rollbackStrategy).toContain(`git restore -- '${file}'`);
    }
    for (const file of plan.filesToCreate) {
      // A created file has nothing in HEAD to restore, so it is removed.
      expect(rollbackStrategy).toContain(`rm -f '${file}'`);
      expect(rollbackStrategy).not.toContain(`git restore -- '${file}'`);
    }
    expect(rollbackStrategy).toContain(SAMPLE_REPO_TEST_COMMAND);
  });
});

describe('generateExecutionPlan target safety', () => {
  it('rejects a create target whose parent symlinks out of the repo', () => {
    const outside = mkdtempSync(path.join(realpathSync.native(os.tmpdir()), 'escape-'));
    const link = inSampleRepo('escape-hatch');
    symlinkSync(outside, link, 'dir');

    try {
      const result = generateExecutionPlan(
        { ...request, filesToModify: [], filesToCreate: ['escape-hatch/pwned.js'] },
        SAMPLE_REPO_ID,
      );

      expect(result.ok).toBe(false);
      if (!result.ok) {
        expect(result.error.code).toBe('TARGET_NOT_EDITABLE');
      }
    } finally {
      rmSync(outside, { force: true, recursive: true });
    }
  });

  it('rejects a create target that already exists on disk', () => {
    const existing = inSampleRepo('already-here.js');
    writeFileSync(existing, 'export const already = true;\n');

    const result = generateExecutionPlan(
      { ...request, filesToModify: [], filesToCreate: ['already-here.js'] },
      SAMPLE_REPO_ID,
    );

    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.error.code).toBe('PLAN_CREATE_TARGET_EXISTS');
    }
  });

  it('rejects a create target that is an in-repo symlink to a file outside the repo', () => {
    const outside = mkdtempSync(path.join(realpathSync.native(os.tmpdir()), 'escape-'));
    const outsideFile = path.join(outside, 'target.js');
    writeFileSync(outsideFile, 'export const outside = true;\n');
    const link = inSampleRepo('linked.js');
    symlinkSync(outsideFile, link, 'file');

    try {
      const result = generateExecutionPlan(
        { ...request, filesToModify: [], filesToCreate: ['linked.js'] },
        SAMPLE_REPO_ID,
      );

      expect(result.ok).toBe(false);
      if (!result.ok) {
        expect(result.error.code).toBe('PLAN_CREATE_TARGET_EXISTS');
      }
    } finally {
      rmSync(outside, { force: true, recursive: true });
    }
  });

  it('rejects a file to modify that symlinks out of the repo', () => {
    const outside = mkdtempSync(path.join(realpathSync.native(os.tmpdir()), 'escape-'));
    const outsideFile = path.join(outside, 'secrets.js');
    writeFileSync(outsideFile, 'export const secret = true;\n');
    const link = inSampleRepo('secrets.js');
    symlinkSync(outsideFile, link, 'file');

    try {
      const result = generateExecutionPlan({ ...request, filesToModify: ['secrets.js'] }, SAMPLE_REPO_ID);

      expect(result.ok).toBe(false);
      if (!result.ok) {
        expect(result.error.code).toBe('TARGET_NOT_EDITABLE');
      }
    } finally {
      rmSync(outside, { force: true, recursive: true });
    }
  });

  it('rejects a file that escapes the repo via ".."', () => {
    const result = generateExecutionPlan(
      { ...request, filesToModify: ['../../package.json'] },
      SAMPLE_REPO_ID,
    );

    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.error.code).toBe('TARGET_NOT_EDITABLE');
    }
  });

  it('rejects an absolute path pointing into the codex-lens repo', () => {
    const result = generateExecutionPlan(
      { ...request, filesToModify: [path.join(CODEX_LENS_REPO_ROOT, 'package.json')] },
      SAMPLE_REPO_ID,
    );

    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.error.code).toBe('TARGET_NOT_EDITABLE');
    }
  });

  it('rejects a file to modify that does not exist', () => {
    const result = generateExecutionPlan(
      { ...request, filesToModify: ['src/nowhere.js'] },
      SAMPLE_REPO_ID,
    );

    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.error.code).toBe('INVALID_TARGET_PATH');
    }
  });

  it('rejects a directory named as a file to modify', () => {
    const result = generateExecutionPlan({ ...request, filesToModify: ['src'] }, SAMPLE_REPO_ID);

    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.error.code).toBe('PLAN_FILE_NOT_A_FILE');
    }
  });
});

describe('generateExecutionPlan request and repo validation', () => {
  it('rejects an unregistered repo', () => {
    const result = generateExecutionPlan(request, 'not-a-registered-repo');

    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.error.code).toBe('UNKNOWN_REPO');
    }
  });

  it('rejects the registered but non-editable codex-lens repo', () => {
    const result = generateExecutionPlan(
      { ...request, filesToModify: ['package.json'] },
      CODEX_LENS_REPO_ID,
    );

    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.error.code).toBe('PLAN_REPO_NOT_EDITABLE');
    }
  });

  it('rejects an empty request text', () => {
    const result = generateExecutionPlan({ ...request, text: '   ' }, SAMPLE_REPO_ID);

    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.error.code).toBe('INVALID_PLAN_REQUEST');
    }
  });

  it('rejects a request that links no engineering plan', () => {
    const result = generateExecutionPlan(
      { ...request, engineeringPlanId: '' },
      SAMPLE_REPO_ID,
    );

    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.error.code).toBe('INVALID_PLAN_REQUEST');
    }
  });

  it('rejects a request that touches no files', () => {
    const result = generateExecutionPlan({ ...request, filesToModify: [] }, SAMPLE_REPO_ID);

    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.error.code).toBe('PLAN_NO_FILES');
    }
  });
});
