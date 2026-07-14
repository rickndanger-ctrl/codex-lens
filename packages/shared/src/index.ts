export const packageName = '@codex-lens/shared';

export {
  ApprovalStatus,
  ApprovalTargetType,
  approvalContractSchema,
  createApprovalContract,
  parseApprovalContract,
  toJSON as approvalContractToJSON,
} from './approval-contract.js';
export type {
  ApprovalContract,
  ApprovalContractInput,
  ApprovalStatus as ApprovalStatusValue,
  ApprovalTarget,
  ApprovalTargetType as ApprovalTargetTypeValue,
} from './approval-contract.js';
export {
  canApproveEngineeringPlan,
  createExecutionPlanFromApproval,
} from './authorization.js';
export type { AuthorizedExecutionPlanInput } from './authorization.js';
export { contentDigest } from './digest.js';
export {
  EngineeringPlanStatus,
  createEngineeringPlan,
  engineeringPlanContentDigest,
  engineeringPlanSchema,
  parseEngineeringPlan,
  toJSON as engineeringPlanToJSON,
  transitionEngineeringPlan,
} from './engineering-plan.js';
export type {
  EngineeringPlan,
  EngineeringPlanInput,
  EngineeringPlanStatus as EngineeringPlanStatusValue,
} from './engineering-plan.js';
export {
  createExecutionPlan,
  ESTIMATE_LEVELS,
  EXECUTION_STATUSES,
  executionPlanSchema,
  parseExecutionPlan,
  transitionExecutionPlan,
  toJSON,
} from './execution-plan.js';
export type {
  CreateExecutionPlanInput,
  EstimateLevel,
  ExecutionPlan,
  ExecutionPlanJson,
  ExecutionStatus,
} from './execution-plan.js';
export { err, ok } from './result.js';
export type { DomainError, Result } from './result.js';
