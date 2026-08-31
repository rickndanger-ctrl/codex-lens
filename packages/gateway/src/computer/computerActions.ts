import { createHash, randomUUID, timingSafeEqual } from 'node:crypto';

import { err, ok, type Result } from '@codex-lens/shared';

import {
  controlComputer,
  type ComputerActionIntent,
  type ComputerActionResult,
  type ComputerController,
  type ComputerSurface,
} from './codexComputer.js';

export interface PreparedComputerAction extends ComputerActionIntent {
  confirmationId: string;
  digest: string;
  expiresAt: string;
  requiresExplicitConfirmation: true;
}

export interface ExecutePreparedComputerActionRequest {
  confirmationId: string;
  digest: string;
}

export interface ComputerActionService {
  prepare(request: ComputerActionIntent): Promise<Result<PreparedComputerAction>>;
  execute(
    request: ExecutePreparedComputerActionRequest,
  ): Promise<Result<ComputerActionResult>>;
}

interface StoredComputerAction extends ComputerActionIntent {
  digest: string;
  expiresAt: Date;
}

export interface CreateComputerActionServiceOptions {
  control?: ComputerController;
  now?: () => Date;
  id?: () => string;
  ttlMs?: number;
}

function digestFor(
  id: string,
  instruction: string,
  surface: ComputerSurface,
  expiresAt: Date,
): string {
  return createHash('sha256')
    .update(id)
    .update('\0')
    .update(instruction)
    .update('\0')
    .update(surface)
    .update('\0')
    .update(expiresAt.toISOString())
    .digest('hex');
}

function digestMatches(presented: string, expected: string): boolean {
  const left = createHash('sha256').update(presented).digest();
  const right = createHash('sha256').update(expected).digest();
  return timingSafeEqual(left, right);
}

export function createComputerActionService(
  options: CreateComputerActionServiceOptions = {},
): ComputerActionService {
  const control = options.control ?? controlComputer;
  const now = options.now ?? (() => new Date());
  const makeId = options.id ?? randomUUID;
  const ttlMs = options.ttlMs ?? 5 * 60_000;
  const prepared = new Map<string, StoredComputerAction>();

  return {
    async prepare(request) {
      const confirmationId = makeId();
      const expiresAt = new Date(now().getTime() + ttlMs);
      const digest = digestFor(
        confirmationId,
        request.instruction,
        request.surface,
        expiresAt,
      );
      prepared.set(confirmationId, {
        ...request,
        digest,
        expiresAt,
      });
      return ok({
        ...request,
        confirmationId,
        digest,
        expiresAt: expiresAt.toISOString(),
        requiresExplicitConfirmation: true,
      });
    },

    async execute(request) {
      const stored = prepared.get(request.confirmationId);
      if (stored === undefined) {
        return err(
          'COMPUTER_CONFIRMATION_NOT_FOUND',
          'That prepared computer action no longer exists. Prepare it again.',
        );
      }
      if (now() >= stored.expiresAt) {
        prepared.delete(request.confirmationId);
        return err(
          'COMPUTER_CONFIRMATION_EXPIRED',
          'That computer-action confirmation expired. Prepare it again.',
        );
      }
      if (!digestMatches(request.digest, stored.digest)) {
        return err(
          'COMPUTER_CONFIRMATION_MISMATCH',
          'The computer-action confirmation did not match. Nothing ran.',
        );
      }

      // Consume before crossing the GUI boundary. If the child times out, its
      // external effect is uncertain and must never be replayed automatically.
      prepared.delete(request.confirmationId);
      return control({
        instruction: stored.instruction,
        surface: stored.surface,
        authorization: 'confirmed',
      });
    },
  };
}
