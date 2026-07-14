import { describe, expect, it } from 'vitest';

import { contentDigest } from './digest.js';
import {
  EngineeringPlanStatus,
  createEngineeringPlan,
  parseEngineeringPlan,
  toJSON,
  type EngineeringPlanInput,
} from './engineering-plan.js';

const validInput: EngineeringPlanInput = {
  engineeringPlanId: 'plan-114',
  version: 1,
  createdAt: '2026-07-14T12:00:00.000Z',
  updatedAt: '2026-07-14T12:00:00.000Z',
  projectName: 'Codex Lens',
  featureName: 'Engineering Plan',
  objective: 'Represent an approved engineering goal.',
  background: 'Plans are reviewed before code is changed.',
  requirements: ['Validate every field', 'Compute a stable digest'],
  constraints: ['Never throw for invalid input'],
  acceptanceCriteria: ['Valid plans round-trip through JSON'],
  assumptions: ['The caller supplies identity and timestamps'],
  risks: ['A stale digest could approve changed content'],
  status: EngineeringPlanStatus.Draft,
};

describe('EngineeringPlan', () => {
  it('constructs a valid immutable plan with a computed content digest', () => {
    const result = createEngineeringPlan(validInput);

    expect(result.ok).toBe(true);
    if (!result.ok) return;

    expect(result.value).not.toBe(validInput);
    expect(result.value.contentDigest).toBe(
      contentDigest({
        projectName: validInput.projectName,
        featureName: validInput.featureName,
        objective: validInput.objective,
        background: validInput.background,
        requirements: validInput.requirements,
        constraints: validInput.constraints,
        acceptanceCriteria: validInput.acceptanceCriteria,
        assumptions: validInput.assumptions,
        risks: validInput.risks,
      }),
    );
    expect(result.value.contentDigest).toMatch(/^[0-9a-f]{64}$/);
    expect(Object.isFrozen(result.value)).toBe(true);
    expect(Object.isFrozen(result.value.requirements)).toBe(true);
  });

  it('rejects an unknown key', () => {
    const result = createEngineeringPlan({
      ...validInput,
      unexpected: true,
    } as EngineeringPlanInput);

    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.error.message).toContain('unexpected');
  });

  it('rejects an invalid status enum value', () => {
    const result = createEngineeringPlan({
      ...validInput,
      status: 'WaitingForApproval',
    } as unknown as EngineeringPlanInput);

    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.error.message).toContain('status');
  });

  it('rejects a non-ISO-8601 date', () => {
    const result = createEngineeringPlan({
      ...validInput,
      createdAt: 'July 14, 2026',
    });

    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.error.message).toContain('createdAt');
  });

  it('rejects an impossible ISO-shaped calendar date', () => {
    const result = createEngineeringPlan({
      ...validInput,
      updatedAt: '2026-02-30T12:00:00.000Z',
    });

    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.error.message).toContain('updatedAt');
  });

  it('round-trips through JSON and returns a deep-equal plan', () => {
    const created = createEngineeringPlan(validInput);
    expect(created.ok).toBe(true);
    if (!created.ok) return;

    const parsed = parseEngineeringPlan(toJSON(created.value));

    expect(parsed).toEqual({ ok: true, value: created.value });
    if (!parsed.ok) return;
    expect(parsed.value).not.toBe(created.value);
    expect(Object.isFrozen(parsed.value)).toBe(true);
  });
});
