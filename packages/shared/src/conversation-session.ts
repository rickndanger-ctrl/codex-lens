import { randomUUID } from 'node:crypto';

import { z } from 'zod';

import { err, ok, type Result } from './result.js';

const CONVERSATION_STATUSES = [
  'Draft',
  'Clarifying',
  'ReadyForPlan',
  'ConvertedToEngineeringPlan',
  'Cancelled',
] as const;

const nonEmptyString = z.string().min(1);
const stringList = z.array(nonEmptyString).readonly();

const openQuestionSchema = z
  .object({
    id: nonEmptyString,
    question: nonEmptyString,
    answer: nonEmptyString.optional(),
  })
  .strict()
  .readonly();

const conversationSessionContentSchema = z.object({
  projectName: nonEmptyString,
  userGoal: nonEmptyString,
  background: z.string(),
  openQuestions: z.array(openQuestionSchema).readonly(),
  confirmedRequirements: stringList,
  confirmedConstraints: stringList,
  confirmedAcceptanceCriteria: stringList,
  assumptions: stringList,
  unresolvedRisks: stringList,
  conversationStatus: z.enum(CONVERSATION_STATUSES),
});

const isoDateTime = z.iso.datetime({ offset: true });

export const ConversationSessionSchema = conversationSessionContentSchema
  .extend({
    conversationId: nonEmptyString,
    createdAt: isoDateTime,
    updatedAt: isoDateTime,
  })
  .strict()
  .readonly();

export type ConversationSession = z.output<typeof ConversationSessionSchema>;

const createConversationSessionInputSchema = conversationSessionContentSchema
  .extend({
    conversationId: nonEmptyString.optional(),
    conversationStatus: z.enum(CONVERSATION_STATUSES).default('Draft'),
  })
  .strict();

export type CreateConversationSessionInput = z.input<
  typeof createConversationSessionInputSchema
>;

function formatIssues(error: z.ZodError): string {
  return error.issues
    .map((issue) => `${issue.path.join('.') || '(root)'}: ${issue.message}`)
    .join('; ');
}

function immutableSession(
  session: z.output<typeof ConversationSessionSchema>,
): ConversationSession {
  return Object.freeze({
    ...session,
    openQuestions: Object.freeze(
      session.openQuestions.map((question) => Object.freeze({ ...question })),
    ),
    confirmedRequirements: Object.freeze([...session.confirmedRequirements]),
    confirmedConstraints: Object.freeze([...session.confirmedConstraints]),
    confirmedAcceptanceCriteria: Object.freeze([
      ...session.confirmedAcceptanceCriteria,
    ]),
    assumptions: Object.freeze([...session.assumptions]),
    unresolvedRisks: Object.freeze([...session.unresolvedRisks]),
  });
}

export function createConversationSession(
  input: CreateConversationSessionInput,
): Result<ConversationSession> {
  const parsedInput = createConversationSessionInputSchema.safeParse(input);
  if (!parsedInput.success) {
    return err('INVALID_CONVERSATION_SESSION', formatIssues(parsedInput.error));
  }

  const now = new Date().toISOString();
  const parsed = ConversationSessionSchema.safeParse({
    ...parsedInput.data,
    conversationId: parsedInput.data.conversationId ?? randomUUID(),
    createdAt: now,
    updatedAt: now,
  });
  if (!parsed.success) {
    return err('INVALID_CONVERSATION_SESSION', formatIssues(parsed.error));
  }

  return ok(immutableSession(parsed.data));
}
