/**
 * Custom error classes for the Unison WASM runtime.
 *
 * @module errors
 */

/**
 * Thrown when attempting to resume a continuation that has already been consumed.
 * Continuations are linear (exactly-once).
 */
export class ContinuationConsumedError extends Error {
  readonly contId: number;

  constructor(contId: number) {
    super(
      `Continuation ${contId} has already been consumed (exactly-once violation)`
    );
    this.name = 'ContinuationConsumedError';
    this.contId = contId;
  }
}

/**
 * Thrown when attempting to start an async operation while another is in-flight.
 * MVP constraint: only one async operation allowed at a time.
 */
export class NestedAsyncError extends Error {
  constructor() {
    super(
      'Cannot yield while another async operation is in-flight (MVP constraint)'
    );
    this.name = 'NestedAsyncError';
  }
}

/**
 * Thrown when attempting to resume with an invalid continuation ID.
 */
export class InvalidContinuationError extends Error {
  readonly expected: number;
  readonly actual: number;

  constructor(expected: number, actual: number) {
    super(`Expected continuation ${expected}, got ${actual}`);
    this.name = 'InvalidContinuationError';
    this.expected = expected;
    this.actual = actual;
  }
}

/**
 * Thrown when apply() receives an argument with the wrong TypeTag.
 */
export class TypeTagMismatchError extends Error {
  readonly expected: string;
  readonly actual: string;

  constructor(expected: string, actual: string) {
    super(`Type mismatch in apply: expected ${expected}, got ${actual}`);
    this.name = 'TypeTagMismatchError';
    this.expected = expected;
    this.actual = actual;
  }
}

/**
 * Thrown when apply() receives too many arguments.
 */
export class ArityError extends Error {
  readonly expected: number;
  readonly actual: number;

  constructor(expected: number, actual: number) {
    super(`Arity mismatch: function expects ${expected} args, got ${actual}`);
    this.name = 'ArityError';
    this.expected = expected;
    this.actual = actual;
  }
}

/**
 * Thrown when an invalid ObjTag is encountered (indicates ABI violation).
 */
export class InvalidObjTagError extends Error {
  readonly tag: number;
  readonly ptr: number;

  constructor(tag: number, ptr: number) {
    super(`Invalid ObjTag 0x${tag.toString(16)} at pointer 0x${ptr.toString(16)} (ABI violation)`);
    this.name = 'InvalidObjTagError';
    this.tag = tag;
    this.ptr = ptr;
  }
}

/**
 * Thrown when an invalid TypeTag is encountered (indicates ABI violation).
 */
export class InvalidTypeTagError extends Error {
  readonly tag: number;
  readonly offset: number;

  constructor(tag: number, offset: number) {
    super(`Invalid TypeTag 0x${tag.toString(16)} at offset 0x${offset.toString(16)} (ABI violation)`);
    this.name = 'InvalidTypeTagError';
    this.tag = tag;
    this.offset = offset;
  }
}

/**
 * Thrown when heap memory is exhausted.
 */
export class OutOfMemoryError extends Error {
  readonly requested: number;
  readonly available: number;

  constructor(requested: number, available: number) {
    super(`Out of memory: requested ${requested} bytes, only ${available} available`);
    this.name = 'OutOfMemoryError';
    this.requested = requested;
    this.available = available;
  }
}
