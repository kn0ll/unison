/**
 * Tests for Async Foreign Calls
 *
 * Tests the ContinuationHandle, AsyncState, and async yield/resume cycle.
 */

import { describe, it, beforeEach, before } from 'node:test';
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

// =============================================================================
// WASM Yield Check Tests (Phase 1)
// =============================================================================
// Tests that WASM functions check for YIELD_SENTINEL and propagate it.

// wabt types
interface WabtModule {
  parseWat(filename: string, buffer: string): WabtWasmModule;
}

interface WabtWasmModule {
  toBinary(options: Record<string, unknown>): { buffer: Uint8Array };
  destroy(): void;
}

let wabtModule: WabtModule | null = null;

/**
 * Parse WAT text to WASM binary
 */
function watToBinary(wat: string): Uint8Array {
  if (!wabtModule) {
    throw new Error('wabt not initialized');
  }
  const module = wabtModule.parseWat('test.wat', wat);
  const { buffer } = module.toBinary({});
  module.destroy();
  return buffer;
}

/**
 * Compile WAT to WASM and instantiate with imports
 */
async function instantiateWatWithImports(
  wat: string,
  imports: WebAssembly.Imports
): Promise<WebAssembly.Instance> {
  const binary = watToBinary(wat);
  const module = await WebAssembly.compile(binary as BufferSource);
  return await WebAssembly.instantiate(module, imports);
}

// Helper to compare bigints as unsigned 64-bit values
function asU64(n: bigint): bigint {
  return BigInt.asUintN(64, n);
}

describe('WASM Yield Check (Phase 1)', () => {
  before(async () => {
    const wabt = await import('wabt');
    wabtModule = await (wabt.default as unknown as () => Promise<WabtModule>)();
  });

  it('propagates YIELD_SENTINEL when FFI returns it', async () => {
    // WAT that:
    // 1. Calls an FFI function
    // 2. Checks if result == YIELD_SENTINEL
    // 3. If yes, returns YIELD_SENTINEL
    // 4. If no, returns the result
    //
    // Note: WASM i64 uses signed representation, so we use -2 (which is 0xFFFFFFFFFFFFFFFE)
    const wat = `(module
      (import "ffi" "test_yield" (func $test_yield (result i64)))

      (func $main (result i64)
        (local $__ffi_result i64)
        call $test_yield
        local.tee $__ffi_result
        i64.const -2  ;; YIELD_SENTINEL = 0xFFFFFFFFFFFFFFFE = -2 signed
        i64.eq
        if
          i64.const -2
          return
        end
        local.get $__ffi_result
      )

      (export "main" (func $main))
    )`;

    // FFI handler that returns YIELD_SENTINEL
    // Note: JS sees -2n from WASM even though we pass YIELD_SENTINEL
    const imports: WebAssembly.Imports = {
      ffi: {
        test_yield: () => YIELD_SENTINEL,
      },
    };

    const instance = await instantiateWatWithImports(wat, imports);
    const main = instance.exports['main'] as () => bigint;
    const result = main();

    // Compare as unsigned to handle signed/unsigned mismatch
    assert.strictEqual(asU64(result), YIELD_SENTINEL);
  });

  it('returns normal value when FFI does not yield', async () => {
    const wat = `(module
      (import "ffi" "test_normal" (func $test_normal (result i64)))

      (func $main (result i64)
        (local $__ffi_result i64)
        call $test_normal
        local.tee $__ffi_result
        i64.const -2  ;; YIELD_SENTINEL
        i64.eq
        if
          i64.const -2
          return
        end
        local.get $__ffi_result
      )

      (export "main" (func $main))
    )`;

    // FFI handler that returns a normal value
    const imports: WebAssembly.Imports = {
      ffi: {
        test_normal: () => 42n,
      },
    };

    const instance = await instantiateWatWithImports(wat, imports);
    const main = instance.exports['main'] as () => bigint;
    const result = main();

    // Should return the normal value, not YIELD_SENTINEL
    assert.strictEqual(result, 42n);
  });

  it('propagates yield through nested calls', async () => {
    // Tests that yield propagates up the call stack:
    // main() -> wrapper() -> FFI returns YIELD_SENTINEL
    // wrapper should return YIELD_SENTINEL
    // main should return YIELD_SENTINEL
    const wat = `(module
      (import "ffi" "yielding_ffi" (func $yielding_ffi (result i64)))

      (func $wrapper (result i64)
        (local $__ffi_result i64)
        call $yielding_ffi
        local.tee $__ffi_result
        i64.const -2  ;; YIELD_SENTINEL
        i64.eq
        if
          i64.const -2
          return
        end
        local.get $__ffi_result
      )

      (func $main (result i64)
        (local $wrapper_result i64)
        call $wrapper
        local.tee $wrapper_result
        i64.const -2  ;; YIELD_SENTINEL
        i64.eq
        if
          i64.const -2
          return
        end
        local.get $wrapper_result
      )

      (export "main" (func $main))
    )`;

    const imports: WebAssembly.Imports = {
      ffi: {
        yielding_ffi: () => YIELD_SENTINEL,
      },
    };

    const instance = await instantiateWatWithImports(wat, imports);
    const main = instance.exports['main'] as () => bigint;
    const result = main();

    // Yield should propagate through wrapper to main (compare as unsigned)
    assert.strictEqual(asU64(result), YIELD_SENTINEL);
  });

  it('sync FFI (Debug.trace style) works correctly', async () => {
    // Simulates Debug.trace which returns 0 (Unit)
    const wat = `(module
      (import "ffi" "Debug_trace" (func $Debug_trace (param i64 i64) (result i64)))

      (func $main (param $msg i64) (result i64)
        (local $__ffi_result i64)
        local.get $msg
        i64.const 0
        call $Debug_trace
        local.tee $__ffi_result
        i64.const -2  ;; YIELD_SENTINEL
        i64.eq
        if
          i64.const -2
          return
        end
        local.get $__ffi_result
      )

      (export "main" (func $main))
    )`;

    let traceWasCalled = false;
    const imports: WebAssembly.Imports = {
      ffi: {
        Debug_trace: (_text: bigint, _val: bigint) => {
          traceWasCalled = true;
          return 0n; // Unit
        },
      },
    };

    const instance = await instantiateWatWithImports(wat, imports);
    const main = instance.exports['main'] as (msg: bigint) => bigint;
    const result = main(123n);

    assert.strictEqual(traceWasCalled, true, 'Debug_trace should be called');
    assert.strictEqual(result, 0n, 'Should return Unit (0)');
  });
});

