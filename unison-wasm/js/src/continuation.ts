/**
 * Continuation Handle for Async Foreign Calls
 *
 * Implements exactly-once enforcement for async continuation resumption.
 * A ContinuationHandle represents a suspended Unison computation that
 * can be resumed with a value when an async operation completes.
 *
 * @module continuation
 */

import type { UnisonRuntime } from './runtime.js';

/**
 * Error thrown when attempting to resume a continuation that was already consumed.
 * This enforces the exactly-once semantics required by the Unison runtime.
 */
export class ContinuationConsumedError extends Error {
  public override readonly name = 'ContinuationConsumedError';

  constructor(public readonly contId: bigint) {
    super(`Continuation ${contId} already consumed (exactly-once violation)`);
  }
}

/**
 * Error thrown when attempting to start a new async operation while one is in-flight.
 * This is an MVP constraint that will be lifted in future versions.
 */
export class NestedAsyncError extends Error {
  public override readonly name = 'NestedAsyncError';

  constructor() {
    super(
      'Nested async operations not supported in MVP. ' +
        'Cannot start new async while one is in-flight. ' +
        'This limitation will be lifted in a future version.'
    );
  }
}

/**
 * Error thrown when attempting to resume with an invalid continuation ID.
 */
export class InvalidContinuationError extends Error {
  public override readonly name = 'InvalidContinuationError';

  constructor(public readonly contId: bigint) {
    super(`Invalid continuation ID: ${contId}`);
  }
}

/**
 * Error thrown when attempting to resume when not in a yielded state.
 */
export class InvalidResumeError extends Error {
  public override readonly name = 'InvalidResumeError';

  constructor(message: string) {
    super(message);
  }
}

/**
 * Handle to a suspended async continuation.
 *
 * This class wraps a continuation ID and enforces exactly-once resumption.
 * The continuation can be resumed with a value (success) or an error (failure).
 *
 * @example
 * ```typescript
 * // In an async foreign function implementation:
 * async function fetchImpl(runtime: UnisonRuntime, url: string): Promise<string> {
 *   const response = await fetch(url);
 *   return await response.text();
 * }
 *
 * // The runtime calls resume() when the Promise resolves
 * handle.resume(result);
 *
 * // Double-resume throws:
 * handle.resume(result2); // throws ContinuationConsumedError
 * ```
 */
export class ContinuationHandle {
  private consumed = false;

  /**
   * Create a new continuation handle.
   *
   * @param id Unique continuation ID
   * @param runtime Reference to the runtime for resumption
   * @internal
   */
  constructor(
    private readonly id: bigint,
    private readonly runtime: UnisonRuntime
  ) {}

  /**
   * Resume the continuation with a successful result.
   *
   * @param value The value to resume with (will be converted to WASM representation)
   * @throws {ContinuationConsumedError} If the continuation was already consumed
   */
  resume(value: unknown): void {
    if (this.consumed) {
      throw new ContinuationConsumedError(this.id);
    }
    this.consumed = true;
    this.runtime.resumeInternal(this.id, value);
  }

  /**
   * Resume the continuation with an error.
   *
   * @param error The error that caused the async operation to fail
   * @throws {ContinuationConsumedError} If the continuation was already consumed
   */
  resumeWithError(error: Error): void {
    if (this.consumed) {
      throw new ContinuationConsumedError(this.id);
    }
    this.consumed = true;
    this.runtime.resumeWithErrorInternal(this.id, error);
  }

  /**
   * Check if this continuation has been consumed.
   */
  get isConsumed(): boolean {
    return this.consumed;
  }

  /**
   * Get the unique ID of this continuation.
   */
  get continuationId(): bigint {
    return this.id;
  }
}

/**
 * Async state machine states.
 *
 * Tracks the current state of async execution in the runtime.
 */
export enum AsyncState {
  /** No async operation in progress */
  Idle = 0,

  /** An async operation has yielded, waiting for resume */
  Yielded = 1,

  /** Currently resuming a continuation */
  Resuming = 2,
}

