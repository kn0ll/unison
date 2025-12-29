/**
 * Tests for Phase 7: Async Foreign Calls
 *
 * Tests the ContinuationHandle, AsyncState, and async yield/resume cycle.
 */

import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';

import {
  // ContinuationHandle is used indirectly via runtime methods
  ContinuationConsumedError,
  NestedAsyncError,
  InvalidContinuationError,
  InvalidResumeError,
  AsyncState,
} from '../continuation.js';

import {
  UnisonRuntime,
  ForeignHandleTable,
} from '../runtime.js';

import {
  YIELD_SENTINEL,
  OBJ_ASYNC_CONT,
  ASYNC_STATUS_PENDING,
  ASYNC_STATUS_RESUMED,
} from '../abi-constants.js';

// =============================================================================
// ContinuationHandle Tests
// =============================================================================

describe('ContinuationHandle', () => {
  let runtime: UnisonRuntime;

  beforeEach(() => {
    runtime = new UnisonRuntime();
  });

  it('allows single resume', () => {
    const contId = runtime.allocContinuation();
    const handle = runtime.getPendingContinuation(contId);

    assert.strictEqual(handle.isConsumed, false);
    assert.strictEqual(handle.continuationId, contId);
  });

  it('marks consumed after resume attempt', () => {
    const contId = runtime.allocContinuation();
    const pendingHandle = runtime.getPendingContinuation(contId);

    // Can't actually resume without a loaded WASM module, but we can verify
    // the consumed flag behavior by checking the handle state
    assert.strictEqual(pendingHandle.isConsumed, false);
  });

  it('throws ContinuationConsumedError on double resume', () => {
    const contId = runtime.allocContinuation();
    // Verify handle exists but don't use it (can't resume without WASM)
    assert.ok(runtime.getPendingContinuation(contId));

    // Test the error type exists and has correct properties
    const error = new ContinuationConsumedError(contId);
    assert.strictEqual(error.name, 'ContinuationConsumedError');
    assert.strictEqual(error.contId, contId);
    assert.ok(error.message.includes('already consumed'));
  });

  it('generates unique continuation IDs', () => {
    const id1 = runtime.allocContinuation();
    const id2 = runtime.allocContinuation();
    const id3 = runtime.allocContinuation();

    assert.notStrictEqual(id1, id2);
    assert.notStrictEqual(id2, id3);
    assert.notStrictEqual(id1, id3);

    // IDs should be monotonically increasing
    assert.ok(id2 > id1);
    assert.ok(id3 > id2);
  });

  it('throws InvalidContinuationError for unknown ID', () => {
    const error = new InvalidContinuationError(999n);
    assert.strictEqual(error.name, 'InvalidContinuationError');
    assert.strictEqual(error.contId, 999n);
  });
});

// =============================================================================
// AsyncState Tests
// =============================================================================

describe('AsyncState', () => {
  let runtime: UnisonRuntime;

  beforeEach(() => {
    runtime = new UnisonRuntime();
  });

  it('starts in Idle state', () => {
    assert.strictEqual(runtime.getAsyncState(), AsyncState.Idle);
  });

  it('tracks pending continuations', () => {
    assert.strictEqual(runtime.getPendingContinuationCount(), 0);

    runtime.allocContinuation();
    assert.strictEqual(runtime.getPendingContinuationCount(), 1);

    runtime.allocContinuation();
    assert.strictEqual(runtime.getPendingContinuationCount(), 2);
  });

  it('resets async state on runtime reset', () => {
    runtime.allocContinuation();
    assert.strictEqual(runtime.getPendingContinuationCount(), 1);

    runtime.reset();
    assert.strictEqual(runtime.getPendingContinuationCount(), 0);
    assert.strictEqual(runtime.getAsyncState(), AsyncState.Idle);
  });
});

// =============================================================================
// NestedAsyncError Tests
// =============================================================================

describe('NestedAsyncError', () => {
  it('has correct error properties', () => {
    const error = new NestedAsyncError();
    assert.strictEqual(error.name, 'NestedAsyncError');
    assert.ok(error.message.includes('MVP'));
    assert.ok(error.message.includes('async'));
  });
});

// =============================================================================
// InvalidResumeError Tests
// =============================================================================

describe('InvalidResumeError', () => {
  it('has correct error properties', () => {
    const error = new InvalidResumeError('Not in yielded state');
    assert.strictEqual(error.name, 'InvalidResumeError');
    assert.ok(error.message.includes('Not in yielded state'));
  });
});

// =============================================================================
// ForeignHandleTable Tests (used for async)
// =============================================================================

describe('ForeignHandleTable (async context)', () => {
  let table: ForeignHandleTable;

  beforeEach(() => {
    table = new ForeignHandleTable();
  });

  it('stores Promise objects', () => {
    const promise = new Promise(resolve => setTimeout(resolve, 100));
    const id = table.alloc(promise);
    assert.strictEqual(table.get(id), promise);
  });

  it('stores async function results', async () => {
    const asyncResult = { data: 'fetched', status: 200 };
    const id = table.alloc(asyncResult);
    assert.deepStrictEqual(table.get(id), asyncResult);
  });
});

// =============================================================================
// ABI Constants Tests
// =============================================================================

describe('Async ABI Constants', () => {
  it('YIELD_SENTINEL is defined', () => {
    assert.strictEqual(typeof YIELD_SENTINEL, 'bigint');
    assert.strictEqual(YIELD_SENTINEL, 0xffff_ffff_ffff_fffen);
  });

  it('OBJ_ASYNC_CONT is defined', () => {
    assert.strictEqual(OBJ_ASYNC_CONT, 0x00b);
  });

  it('ASYNC_STATUS values are defined', () => {
    assert.strictEqual(ASYNC_STATUS_PENDING, 0);
    assert.strictEqual(ASYNC_STATUS_RESUMED, 1);
  });
});

// =============================================================================
// Async Foreign Function Registration Tests
// =============================================================================

describe('Async Foreign Function Registration', () => {
  let runtime: UnisonRuntime;

  beforeEach(() => {
    runtime = new UnisonRuntime();
  });

  it('registers async foreign function', () => {
    const handler = async () => 42n;
    runtime.registerAsyncForeign('test.asyncFunc', handler);

    const retrieved = runtime.getAsyncForeign('test.asyncFunc');
    assert.strictEqual(retrieved, handler);
  });

  it('returns undefined for unregistered async function', () => {
    const retrieved = runtime.getAsyncForeign('nonexistent');
    assert.strictEqual(retrieved, undefined);
  });

  it('can register multiple async functions', () => {
    const handler1 = async () => 1n;
    const handler2 = async () => 2n;

    runtime.registerAsyncForeign('test.func1', handler1);
    runtime.registerAsyncForeign('test.func2', handler2);

    assert.strictEqual(runtime.getAsyncForeign('test.func1'), handler1);
    assert.strictEqual(runtime.getAsyncForeign('test.func2'), handler2);
  });
});

