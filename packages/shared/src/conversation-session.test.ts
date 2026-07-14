import { describe, expect, it } from 'vitest';

import {
  ConversationSessionSchema,
  createConversationSession,
  type CreateConversationSessionInput,
} from './conversation-session.js';

const validInput: CreateConversationSessionInput = {
  projectName: 'Codex Lens',
  userGoal: 'Turn a clarified conversation into an engineering plan.',
  background: 'The user and AI engineer refine the work before planning.',
  openQuestions: [
    {
      id: 'question-1',
      question: 'Which platforms must be supported?',
    },
  ],
  confirmedRequirements: ['Capture the user goal'],
  confirmedConstraints: ['Never throw for invalid input'],
  confirmedAcceptanceCriteria: ['Valid sessions pass schema validation'],
  assumptions: ['The caller provides the conversation content'],
  unresolvedRisks: ['Requirements may still change'],
};

describe('createConversationSession', () => {
  it('creates a valid frozen session with generated metadata and Draft status', () => {
    const result = createConversationSession(validInput);

    expect(result.ok).toBe(true);
    if (!result.ok) return;

    expect(ConversationSessionSchema.safeParse(result.value).success).toBe(
      true,
    );
    expect(result.value.conversationId).toMatch(/^[0-9a-f-]{36}$/);
    expect(result.value.createdAt).toBe(result.value.updatedAt);
    expect(result.value.conversationStatus).toBe('Draft');
    expect(Object.isFrozen(result.value)).toBe(true);
    expect(Object.isFrozen(result.value.openQuestions)).toBe(true);
    expect(Object.isFrozen(result.value.openQuestions[0])).toBe(true);
    expect(Object.isFrozen(result.value.confirmedRequirements)).toBe(true);
  });

  it('preserves a supplied conversationId and status', () => {
    const result = createConversationSession({
      ...validInput,
      conversationId: 'conversation-124',
      conversationStatus: 'Clarifying',
    });

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.conversationId).toBe('conversation-124');
    expect(result.value.conversationStatus).toBe('Clarifying');
  });

  it('returns an error instead of throwing when userGoal is missing', () => {
    const invalidInput = { ...validInput } as Record<string, unknown>;
    delete invalidInput.userGoal;

    expect(() =>
      createConversationSession(
        invalidInput as unknown as CreateConversationSessionInput,
      ),
    ).not.toThrow();

    const result = createConversationSession(
      invalidInput as unknown as CreateConversationSessionInput,
    );
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.error.code).toBe('INVALID_CONVERSATION_SESSION');
    expect(result.error.message).toContain('userGoal');
  });

  it('rejects unknown fields', () => {
    const result = createConversationSession({
      ...validInput,
      unexpected: true,
    } as CreateConversationSessionInput);

    expect(result.ok).toBe(false);
  });
});
