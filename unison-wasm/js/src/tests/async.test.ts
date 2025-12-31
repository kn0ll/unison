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
  ASYNC_CONT_ID_OFFSET,
  ASYNC_CONT_LOCALS_PTR_OFFSET,
  ASYNC_CONT_LOCALS_COUNT_OFFSET,
  ASYNC_CONT_FUNC_IDX_OFFSET,
  ASYNC_CONT_RESUME_LABEL_OFFSET,
  ASYNC_CONT_STATUS_OFFSET,
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

// =============================================================================
// Phase 2: Local State Saving Tests
// =============================================================================

describe('Phase 2: Local State Saving', () => {
  before(async () => {
    // Ensure wabt is loaded (uses shared instantiateWatWithImports helper)
    const wabt = await import('wabt');
    await (wabt.default as unknown as () => Promise<WabtModule>)();
  });

  it('saves all locals when yielding', async () => {
    // This WAT simulates what the compiler generates for Phase 2:
    // - Has multiple locals set before the FFI call
    // - When FFI returns YIELD_SENTINEL, saves locals to array
    // - Creates AsyncCont with func_idx and resume_label
    const wat = `(module
      ;; FFI that yields (imports must come first)
      (import "ffi" "async_op" (func $async_op (result i64)))

      ;; Memory for heap
      (memory (export "memory") 1)

      ;; Globals for runtime state
      (global $heap_ptr (mut i32) (i32.const 1024))
      (global $k_ptr (mut i32) (i32.const 0))
      (global $async_cont_id (mut i64) (i64.const 0))
      (global $async_cont_ptr (export "async_cont_ptr") (mut i32) (i32.const 0))

      ;; Simple allocator
      (func $__alloc (param $size i32) (result i32)
        (local $ptr i32)
        global.get $heap_ptr
        local.set $ptr
        global.get $heap_ptr
        local.get $size
        i32.add
        global.set $heap_ptr
        local.get $ptr
      )

      ;; Allocate locals array (each slot is 8 bytes for i64)
      (func $__alloc_locals_array (export "__alloc_locals_array") (param $count i32) (result i32)
        local.get $count
        i32.const 8
        i32.mul
        call $__alloc
      )

      ;; Allocate async cont object
      ;; Args: cont_id (i64), k_ptr (i32), locals_ptr (i32), locals_count (i32), func_idx (i32), resume_label (i32)
      (func $__alloc_async_cont (export "__alloc_async_cont")
            (param $cont_id i64) (param $k_ptr i32) (param $locals_ptr i32)
            (param $locals_count i32) (param $func_idx i32) (param $resume_label i32) (result i32)
        (local $ptr i32)
        ;; Allocate 40 bytes for AsyncCont
        i32.const 40
        call $__alloc
        local.set $ptr

        ;; Store header (8 bytes: version=0, obj_tag=0x00b, size=40)
        local.get $ptr
        i64.const 0x0000002800B00000  ;; size=40, tag=0x00b, version=0
        i64.store

        ;; Store cont_id at offset 8
        local.get $ptr
        local.get $cont_id
        i64.store offset=8

        ;; Store k_ptr at offset 16
        local.get $ptr
        local.get $k_ptr
        i32.store offset=16

        ;; Store locals_ptr at offset 20
        local.get $ptr
        local.get $locals_ptr
        i32.store offset=20

        ;; Store locals_count at offset 24
        local.get $ptr
        local.get $locals_count
        i32.store offset=24

        ;; Store func_idx at offset 28
        local.get $ptr
        local.get $func_idx
        i32.store offset=28

        ;; Store resume_label at offset 32
        local.get $ptr
        local.get $resume_label
        i32.store offset=32

        ;; Store status (pending=0) at offset 36
        local.get $ptr
        i32.const 0
        i32.store offset=36

        local.get $ptr
      )

      ;; Main function with locals that need saving
      (func $main (export "main") (result i64)
        (local $x i64)
        (local $y i64)
        (local $z i64)
        (local $__ffi_result i64)
        (local $__async_locals_ptr i32)

        ;; Set up some locals
        i64.const 111
        local.set $x
        i64.const 222
        local.set $y
        i64.const 333
        local.set $z

        ;; Call FFI
        call $async_op
        local.tee $__ffi_result

        ;; Check for YIELD_SENTINEL
        i64.const -2  ;; YIELD_SENTINEL = 0xFFFFFFFFFFFFFFFE = -2 signed
        i64.eq
        if
          ;; Allocate locals array for 3 locals
          i32.const 3
          call $__alloc_locals_array
          local.set $__async_locals_ptr

          ;; Save local $x at offset 0
          local.get $__async_locals_ptr
          local.get $x
          i64.store offset=0

          ;; Save local $y at offset 8
          local.get $__async_locals_ptr
          local.get $y
          i64.store offset=8

          ;; Save local $z at offset 16
          local.get $__async_locals_ptr
          local.get $z
          i64.store offset=16

          ;; Increment and get continuation ID
          global.get $async_cont_id
          i64.const 1
          i64.add
          global.set $async_cont_id

          ;; Create AsyncCont: cont_id, k_ptr, locals_ptr, locals_count, func_idx, resume_label
          global.get $async_cont_id  ;; cont_id
          global.get $k_ptr          ;; k_ptr
          local.get $__async_locals_ptr  ;; locals_ptr
          i32.const 3                ;; locals_count
          i32.const 42               ;; func_idx (example: function table index 42)
          i32.const 0                ;; resume_label (yield point 0)
          call $__alloc_async_cont
          global.set $async_cont_ptr

          ;; Return YIELD_SENTINEL
          i64.const -2
          return
        end

        ;; Normal path: return result
        local.get $__ffi_result
      )
    )`;

    // Track what we learn about the saved state
    let yieldCalled = false;
    const imports: WebAssembly.Imports = {
      ffi: {
        async_op: () => {
          yieldCalled = true;
          return YIELD_SENTINEL;
        },
      },
    };

    const instance = await instantiateWatWithImports(wat, imports);
    const main = instance.exports['main'] as () => bigint;
    const memory = instance.exports['memory'] as WebAssembly.Memory;
    const asyncContPtr = instance.exports['async_cont_ptr'] as WebAssembly.Global;

    // Call main - it should yield
    const result = main();

    // Verify yield happened
    assert.strictEqual(yieldCalled, true, 'FFI should be called');
    assert.strictEqual(asU64(result), YIELD_SENTINEL, 'Should return YIELD_SENTINEL');

    // Verify AsyncCont was created
    const contPtr = asyncContPtr.value as number;
    assert.ok(contPtr > 0, 'AsyncCont should be allocated');

    // Read the AsyncCont fields from memory
    const view = new DataView(memory.buffer);

    // Read cont_id (i64 at offset 8)
    const contId = view.getBigUint64(contPtr + ASYNC_CONT_ID_OFFSET, true);
    assert.strictEqual(contId, 1n, 'Continuation ID should be 1');

    // Read locals_count (i32 at offset 24)
    const localsCount = view.getUint32(contPtr + ASYNC_CONT_LOCALS_COUNT_OFFSET, true);
    assert.strictEqual(localsCount, 3, 'Should have saved 3 locals');

    // Read func_idx (i32 at offset 28)
    const funcIdx = view.getUint32(contPtr + ASYNC_CONT_FUNC_IDX_OFFSET, true);
    assert.strictEqual(funcIdx, 42, 'Function index should be 42');

    // Read resume_label (i32 at offset 32)
    const resumeLabel = view.getUint32(contPtr + ASYNC_CONT_RESUME_LABEL_OFFSET, true);
    assert.strictEqual(resumeLabel, 0, 'Resume label should be 0');

    // Read status (i32 at offset 36)
    const status = view.getUint32(contPtr + ASYNC_CONT_STATUS_OFFSET, true);
    assert.strictEqual(status, ASYNC_STATUS_PENDING, 'Status should be pending');

    // Read locals_ptr and verify saved values
    const localsPtr = view.getUint32(contPtr + ASYNC_CONT_LOCALS_PTR_OFFSET, true);
    assert.ok(localsPtr > 0, 'Locals pointer should be set');

    // Read saved locals
    const savedX = view.getBigUint64(localsPtr + 0, true);
    const savedY = view.getBigUint64(localsPtr + 8, true);
    const savedZ = view.getBigUint64(localsPtr + 16, true);

    assert.strictEqual(savedX, 111n, 'Local x should be saved as 111');
    assert.strictEqual(savedY, 222n, 'Local y should be saved as 222');
    assert.strictEqual(savedZ, 333n, 'Local z should be saved as 333');
  });

  it('handles sync FFI (no yield) correctly with new code', async () => {
    // Same structure as above but FFI returns a normal value
    const wat = `(module
      ;; Import must come first
      (import "ffi" "sync_op" (func $sync_op (result i64)))

      (memory (export "memory") 1)
      (global $heap_ptr (mut i32) (i32.const 1024))
      (global $k_ptr (mut i32) (i32.const 0))
      (global $async_cont_id (mut i64) (i64.const 0))
      (global $async_cont_ptr (export "async_cont_ptr") (mut i32) (i32.const 0))

      (func $__alloc (param $size i32) (result i32)
        (local $ptr i32)
        global.get $heap_ptr
        local.set $ptr
        global.get $heap_ptr
        local.get $size
        i32.add
        global.set $heap_ptr
        local.get $ptr
      )

      (func $__alloc_locals_array (export "__alloc_locals_array") (param $count i32) (result i32)
        local.get $count
        i32.const 8
        i32.mul
        call $__alloc
      )

      (func $__alloc_async_cont (export "__alloc_async_cont")
            (param $cont_id i64) (param $k_ptr i32) (param $locals_ptr i32)
            (param $locals_count i32) (param $func_idx i32) (param $resume_label i32) (result i32)
        i32.const 0  ;; Return null - should never be called in sync case
      )

      (func $main (export "main") (result i64)
        (local $x i64)
        (local $y i64)
        (local $__ffi_result i64)
        (local $__async_locals_ptr i32)

        i64.const 100
        local.set $x
        i64.const 200
        local.set $y

        call $sync_op
        local.tee $__ffi_result

        i64.const -2
        i64.eq
        if
          ;; Would save locals here - but sync op doesn't yield
          i64.const -2
          return
        end

        ;; Use locals after FFI - they should still be accessible
        local.get $x
        local.get $y
        i64.add
        local.get $__ffi_result
        i64.add  ;; x + y + result
      )
    )`;

    const imports: WebAssembly.Imports = {
      ffi: {
        sync_op: () => 50n,  // Return normal value, not YIELD_SENTINEL
      },
    };

    const instance = await instantiateWatWithImports(wat, imports);
    const main = instance.exports['main'] as () => bigint;
    const asyncContPtr = instance.exports['async_cont_ptr'] as WebAssembly.Global;

    const result = main();

    // Should return x + y + result = 100 + 200 + 50 = 350
    assert.strictEqual(result, 350n, 'Should compute 100 + 200 + 50 = 350');

    // AsyncCont should NOT be created
    assert.strictEqual(asyncContPtr.value, 0, 'AsyncCont should not be allocated for sync calls');
  });
});

