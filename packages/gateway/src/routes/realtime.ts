import type { FastifyInstance } from 'fastify';
import { z } from 'zod';

import {
  BoundaryBadRequestSchema,
  validateBoundary,
} from '../http/validation.js';
import {
  REALTIME_CREDENTIALS_PATH,
  RealtimeCredentialRequestSchema,
  RealtimeCredentialSchema,
  type RealtimeCredentialIssuer,
} from '../realtime/credentials.js';

export { REALTIME_CREDENTIALS_PATH } from '../realtime/credentials.js';

export const RealtimeUnavailableSchema = z
  .object({
    statusCode: z.literal(503),
    error: z.literal('Service Unavailable'),
    message: z.string().min(1),
  })
  .strict();

function jsonSchema(schema: z.ZodType): Record<string, unknown> {
  return z.toJSONSchema(schema, { target: 'draft-7' });
}

/**
 * `POST /v1/realtime/credentials` — the phone trades its gateway bearer token
 * (enforced by the shared auth hook) for a short-lived OpenAI Realtime
 * credential. Fails closed with 503 when no issuer is configured, so a
 * misconfigured gateway can never hand out or require the long-lived key.
 */
export function registerRealtimeRoute(
  server: FastifyInstance,
  issuer: RealtimeCredentialIssuer | undefined,
): void {
  server.post(
    REALTIME_CREDENTIALS_PATH,
    {
      schema: {
        body: jsonSchema(RealtimeCredentialRequestSchema),
        response: {
          200: jsonSchema(RealtimeCredentialSchema),
          400: jsonSchema(BoundaryBadRequestSchema),
          503: jsonSchema(RealtimeUnavailableSchema),
        },
      },
    },
    async (request, reply) => {
      const body = validateBoundary(
        RealtimeCredentialRequestSchema,
        request.body ?? {},
        'INVALID_REALTIME_CREDENTIAL_REQUEST',
      );
      if (!body.ok) {
        return reply.code(400).send({
          statusCode: 400,
          error: 'Bad Request',
          message: body.error.message,
        });
      }

      if (issuer === undefined) {
        return reply.code(503).send({
          statusCode: 503,
          error: 'Service Unavailable',
          message: 'Realtime credentials are not configured on this gateway.',
        });
      }

      const issued = await issuer(body.value);
      if (!issued.ok) {
        // Log the code only — never the upstream detail or any secret.
        request.log.error(
          { code: issued.error.code },
          'realtime credential issuance failed',
        );
        return reply.code(503).send({
          statusCode: 503,
          error: 'Service Unavailable',
          message: 'Could not issue a realtime credential right now.',
        });
      }

      const response = validateBoundary(
        RealtimeCredentialSchema,
        issued.value,
        'INVALID_REALTIME_CREDENTIAL_RESPONSE',
      );
      if (!response.ok) {
        throw new Error(response.error.message);
      }

      return response.value;
    },
  );
}
