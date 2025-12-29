/**
 * Unison WASM Runtime
 *
 * This module provides the main runtime class for loading and executing
 * Unison WASM modules with JS interop, including async operations.
 *
 * @module runtime
 */

import {
  TEXT_BYTELEN_OFFSET,
  TEXT_BYTES_OFFSET,
  FOREIGN_HANDLE_OFFSET,
  OBJ_PAP,
  TYPE_NAT,
  TYPE_INT,
  TYPE_FLOAT,
  TYPE_CHAR,
  TYPE_BOXED,
  PAP_EXPECTED_ARITY_OFFSET,
  PAP_CAPTURED_COUNT_OFFSET,
  PAP_ARGS_OFFSET,
  TYPED_SLOT_SIZE,
  SLOT_TAG_OFFSET,
  HEADER_OBJTAG_SHIFT,
  HEADER_OBJTAG_MASK,
  OBJ_TAG_NAMES,
  YIELD_SENTINEL,
  type Ptr32,
  type TypeTag,
  type ObjTag,
} from './abi-constants.js';

import { ArityError } from './errors.js';

import {
  ContinuationHandle,
  AsyncState,
  NestedAsyncError,
  InvalidContinuationError,
  InvalidResumeError,
} from './continuation.js';

// =============================================================================
// Types
// =============================================================================

/**
 * WASM imports provided to the module.
 */
export interface UnisonImports {
  [namespace: string]: {
    [name: string]: (...args: any[]) => any;
  };
}

/**
 * WASM exports from a loaded module.
 */
export interface UnisonExports {
  memory: WebAssembly.Memory;
  [name: string]: any;
}

/**
 * Foreign function definition for registration (sync).
 */
export interface ForeignDef {
  name: string;
  handler: (runtime: UnisonRuntime, ...args: number[]) => number | void;
}

/**
 * Async foreign function definition.
 */
export interface AsyncForeignDef {
  name: string;
  handler: (runtime: UnisonRuntime, ...args: number[]) => Promise<bigint>;
}

// =============================================================================
// Foreign Handle Table
// =============================================================================

/**
 * Table for storing JS objects referenced by WASM.
 * WASM holds an integer handle ID; this table maps ID -> JS value.
 */
export class ForeignHandleTable {
  private handles: Map<number, any> = new Map();
  private nextId: number = 1; // Start at 1, 0 is reserved for null

  /**
   * Allocate a handle for a JS value.
   */
  alloc(value: any): number {
    const id = this.nextId++;
    this.handles.set(id, value);
    return id;
  }

  /**
   * Get the JS value for a handle ID.
   */
  get(id: number): any {
    if (id === 0) return null;
    const value = this.handles.get(id);
    if (value === undefined) {
      throw new Error(`Invalid foreign handle: ${id}`);
    }
    return value;
  }

  /**
   * Free a handle (allows GC of the JS value).
   */
  free(id: number): void {
    if (id !== 0) {
      this.handles.delete(id);
    }
  }

  /**
   * Get all active handles (for debugging).
   */
  getAll(): Map<number, any> {
    return new Map(this.handles);
  }

  /**
   * Clear all handles.
   */
  clear(): void {
    this.handles.clear();
    this.nextId = 1;
  }
}

// =============================================================================
// Unison Runtime
// =============================================================================

/**
 * Main runtime class for Unison WASM execution.
 *
 * Provides:
 * - WASM module loading
 * - Foreign function dispatch (sync and async)
 * - Memory access (getText, getBytes)
 * - Apply protocol for closures
 * - Async yield/resume for IO operations
 * - Debug utilities
 */
export class UnisonRuntime {
  private memory: WebAssembly.Memory | null = null;
  private exports: UnisonExports | null = null;

  /** Foreign handle table for JS objects */
  readonly handles: ForeignHandleTable = new ForeignHandleTable();

  /** Registered sync foreign functions */
  private foreignFuncs: Map<string, ForeignDef['handler']> = new Map();

  /** Registered async foreign functions */
  private asyncForeignFuncs: Map<string, AsyncForeignDef['handler']> = new Map();

  /** Console output captured during execution (for testing) */
  capturedOutput: string[] = [];

  // ===========================================================================
  // Async State Machine
  // ===========================================================================

  /** Current async state */
  private asyncState: AsyncState = AsyncState.Idle;

  /** Monotonically increasing continuation ID counter */
  private nextContId: bigint = 1n;

  /** Active continuations waiting for resume */
  private pendingContinuations: Map<bigint, ContinuationHandle> = new Map();

  /** Promise resolve callback for current run() */
  private resolveRun: ((value: bigint) => void) | null = null;

  /** Promise reject callback for current run() */
  private rejectRun: ((error: Error) => void) | null = null;


  // ===========================================================================
  // Module Loading
  // ===========================================================================

  /**
   * Load a WASM module from bytes.
   *
   * @param wasmBytes - The WASM binary or WAT source
   * @param customImports - Additional imports to merge with defaults
   */
  async loadWasm(
    wasmBytes: BufferSource,
    customImports: UnisonImports = {}
  ): Promise<void> {
    const imports = this.buildImports(customImports);
    const result = await WebAssembly.instantiate(wasmBytes, imports);

    this.exports = result.instance.exports as UnisonExports;
    this.memory = this.exports.memory;
  }

  /**
   * Load a WASM module from a file path (Node.js).
   */
  async loadWasmFile(path: string, customImports: UnisonImports = {}): Promise<void> {
    const fs = await import('fs/promises');
    const bytes = await fs.readFile(path);
    await this.loadWasm(bytes, customImports);
  }

  /**
   * Build the full imports object for WASM instantiation.
   */
  private buildImports(customImports: UnisonImports): WebAssembly.Imports {
    const unisonNamespace: Record<string, (...args: any[]) => any> = {};

    // Add registered foreign functions
    for (const [name, handler] of this.foreignFuncs) {
      unisonNamespace[name] = (...args: number[]) => handler(this, ...args);
    }

    // Add default foreign functions
    this.addDefaultForeignFuncs(unisonNamespace);

    return {
      unison: unisonNamespace,
      ...customImports,
    };
  }

  /**
   * Add default foreign functions (IO.printLine, etc.)
   */
  private addDefaultForeignFuncs(ns: Record<string, (...args: any[]) => any>): void {
    // IO.printLine: (textPtr: i32) -> ()
    ns['printLine'] = (textPtr: number) => {
      const text = this.getText(textPtr);
      console.log(text);
      this.capturedOutput.push(text);
    };

    // IO.print: (textPtr: i32) -> ()
    ns['print'] = (textPtr: number) => {
      const text = this.getText(textPtr);
      process.stdout.write(text);
      this.capturedOutput.push(text);
    };

    // Debug.trace: (textPtr: i32, value: i64) -> i64
    ns['trace'] = (textPtr: number, value: bigint): bigint => {
      const text = this.getText(textPtr);
      console.log(`[TRACE] ${text}: ${value}`);
      return value;
    };

    // Add async foreign function wrappers
    this.addAsyncForeignFuncWrappers(ns);
  }

  /**
   * Add wrappers for async foreign functions.
   *
   * These wrappers:
   * 1. Allocate a continuation ID
   * 2. Start the async operation
   * 3. Return YIELD_SENTINEL to yield to JS
   * 4. When Promise resolves, resume the continuation
   */
  private addAsyncForeignFuncWrappers(ns: Record<string, (...args: any[]) => any>): void {
    // IO.fetch: (urlPtr: i32) -> Text (async)
    if (!this.asyncForeignFuncs.has('IO.fetch')) {
      this.registerAsyncForeign('IO.fetch', async (_runtime, urlPtr: number) => {
        const url = this.getText(urlPtr);
        const response = await fetch(url);
        const text = await response.text();
        // Allocate text in WASM memory and return pointer
        // For now, return the length as a placeholder
        return BigInt(text.length);
      });
    }

    // IO.delay: (ms: i64) -> () (async)
    if (!this.asyncForeignFuncs.has('IO.delay')) {
      this.registerAsyncForeign('IO.delay', async (_runtime, ms: number) => {
        await new Promise(resolve => setTimeout(resolve, ms));
        return 0n; // Unit
      });
    }

    // Wire up async functions to namespace
    for (const [name, handler] of this.asyncForeignFuncs) {
      const wrapperName = name.replace('.', '_');
      ns[wrapperName] = (...args: number[]) => {
        // Check for nested async
        if (this.asyncState === AsyncState.Yielded) {
          throw new NestedAsyncError();
        }

        // Allocate continuation
        const contId = this.allocContinuation();

        // Start async operation
        handler(this, ...args)
          .then(result => {
            const handle = this.pendingContinuations.get(contId);
            if (handle && !handle.isConsumed) {
              handle.resume(result);
            }
          })
          .catch(error => {
            const handle = this.pendingContinuations.get(contId);
            if (handle && !handle.isConsumed) {
              handle.resumeWithError(error instanceof Error ? error : new Error(String(error)));
            }
          });

        // Return yield sentinel
        return YIELD_SENTINEL;
      };
    }
  }

  // ===========================================================================
  // Foreign Function Registration
  // ===========================================================================

  /**
   * Register a sync foreign function that WASM can call.
   */
  registerForeign(name: string, handler: ForeignDef['handler']): void {
    this.foreignFuncs.set(name, handler);
  }

  /**
   * Register multiple sync foreign functions.
   */
  registerForeignBatch(defs: ForeignDef[]): void {
    for (const def of defs) {
      this.registerForeign(def.name, def.handler);
    }
  }

  /**
   * Register an async foreign function.
   *
   * Async foreign functions return a Promise. When called from WASM,
   * the runtime will yield, wait for the Promise to resolve, then
   * resume the continuation with the result.
   */
  registerAsyncForeign(name: string, handler: AsyncForeignDef['handler']): void {
    this.asyncForeignFuncs.set(name, handler);
  }

  /**
   * Get an async foreign function handler.
   * @internal
   */
  getAsyncForeign(name: string): AsyncForeignDef['handler'] | undefined {
    return this.asyncForeignFuncs.get(name);
  }

  // ===========================================================================
  // Function Calls
  // ===========================================================================

  /**
   * Call an exported WASM function by name.
   */
  call(funcName: string, ...args: any[]): any {
    if (!this.exports) {
      throw new Error('No WASM module loaded');
    }
    const fn = this.exports[funcName];
    if (typeof fn !== 'function') {
      throw new Error(`Export '${funcName}' is not a function`);
    }
    return fn(...args);
  }

  /**
   * Call an exported function and get result as a number.
   */
  callNumber(funcName: string, ...args: any[]): number {
    const result = this.call(funcName, ...args);
    return Number(result);
  }

  /**
   * Call an exported function and get result as a bigint.
   */
  callBigInt(funcName: string, ...args: any[]): bigint {
    const result = this.call(funcName, ...args);
    return BigInt(result);
  }

  // ===========================================================================
  // Async Execution
  // ===========================================================================

  /**
   * Run a function that may perform async operations.
   *
   * Returns a Promise that resolves when the computation completes,
   * which may involve multiple yield/resume cycles for async IO.
   *
   * @param funcName - Name of the exported function to call
   * @param args - Arguments to pass to the function
   * @returns Promise resolving to the final result
   */
  async run(funcName: string, ...args: any[]): Promise<bigint> {
    // Check for nested async (MVP constraint)
    if (this.asyncState !== AsyncState.Idle) {
      throw new NestedAsyncError();
    }

    return new Promise((resolve, reject) => {
      this.resolveRun = resolve;
      this.rejectRun = reject;

      try {
        const result = this.call(funcName, ...args);
        const resultBigInt = typeof result === 'bigint' ? result : BigInt(result);

        // Check if the function yielded
        if (resultBigInt === YIELD_SENTINEL) {
          // Async operation started, will resume later
          this.asyncState = AsyncState.Yielded;
          // Don't resolve yet - wait for resume
        } else {
          // Sync completion
          this.asyncState = AsyncState.Idle;
          this.resolveRun = null;
          this.rejectRun = null;
          resolve(resultBigInt);
        }
      } catch (error) {
        this.asyncState = AsyncState.Idle;
        this.resolveRun = null;
        this.rejectRun = null;
        reject(error);
      }
    });
  }

  /**
   * Get the current async state.
   */
  getAsyncState(): AsyncState {
    return this.asyncState;
  }

  /**
   * Allocate a continuation ID and create a handle.
   * Called by async foreign functions before yielding.
   *
   * @returns The continuation ID for this yield
   * @internal
   */
  allocContinuation(): bigint {
    const id = this.nextContId++;
    const handle = new ContinuationHandle(id, this);
    this.pendingContinuations.set(id, handle);
    return id;
  }

  /**
   * Get the pending continuation handle.
   * @internal
   */
  getPendingContinuation(contId: bigint): ContinuationHandle {
    const handle = this.pendingContinuations.get(contId);
    if (!handle) {
      throw new InvalidContinuationError(contId);
    }
    return handle;
  }

  /**
   * Resume a yielded computation with a value.
   * Called by ContinuationHandle.resume().
   *
   * @param contId - The continuation ID
   * @param value - The value to resume with
   * @internal
   */
  resumeInternal(contId: bigint, value: unknown): void {
    if (this.asyncState !== AsyncState.Yielded) {
      throw new InvalidResumeError(
        `Cannot resume: not in Yielded state (current: ${AsyncState[this.asyncState]})`
      );
    }

    // Remove from pending
    this.pendingContinuations.delete(contId);

    // Convert value to i64
    const wasmValue = this.valueToWasm(value);

    this.asyncState = AsyncState.Resuming;

    try {
      // Call WASM resume function
      if (!this.exports || typeof this.exports['__resume'] !== 'function') {
        throw new Error('__resume export not found');
      }

      const result = this.exports['__resume'](contId, wasmValue);
      const resultBigInt = typeof result === 'bigint' ? result : BigInt(result);

      if (resultBigInt === YIELD_SENTINEL) {
        // Yielded again (sequential async)
        this.asyncState = AsyncState.Yielded;
      } else {
        // Final result
        this.asyncState = AsyncState.Idle;
        if (this.resolveRun) {
          this.resolveRun(resultBigInt);
          this.resolveRun = null;
          this.rejectRun = null;
        }
      }
    } catch (error) {
      this.asyncState = AsyncState.Idle;
      if (this.rejectRun) {
        this.rejectRun(error instanceof Error ? error : new Error(String(error)));
        this.resolveRun = null;
        this.rejectRun = null;
      }
    }
  }

  /**
   * Resume a yielded computation with an error.
   * Called by ContinuationHandle.resumeWithError().
   *
   * @param contId - The continuation ID
   * @param error - The error to propagate
   * @internal
   */
  resumeWithErrorInternal(contId: bigint, error: Error): void {
    // Remove from pending
    this.pendingContinuations.delete(contId);

    // Propagate to run() Promise
    this.asyncState = AsyncState.Idle;
    if (this.rejectRun) {
      this.rejectRun(error);
      this.resolveRun = null;
      this.rejectRun = null;
    }
  }

  /**
   * Convert a JS value to WASM i64 representation.
   */
  private valueToWasm(value: unknown): bigint {
    if (typeof value === 'bigint') return value;
    if (typeof value === 'number') return BigInt(Math.floor(value));
    if (typeof value === 'boolean') return value ? 1n : 0n;
    if (value === null || value === undefined) return 0n;

    // For objects, allocate a foreign handle
    if (typeof value === 'object') {
      const handleId = this.handles.alloc(value);
      return BigInt(handleId);
    }

    throw new Error(`Cannot convert ${typeof value} to WASM value`);
  }

  // ===========================================================================
  // Memory Access
  // ===========================================================================

  /**
   * Get the memory DataView.
   */
  getMemoryView(): DataView {
    if (!this.memory) {
      throw new Error('No WASM module loaded');
    }
    return new DataView(this.memory.buffer);
  }

  /**
   * Read a UTF-8 string from a Text object in memory.
   */
  getText(ptr: Ptr32): string {
    const view = this.getMemoryView();
    const byteLen = view.getUint32(ptr + TEXT_BYTELEN_OFFSET, true);
    const bytesStart = ptr + TEXT_BYTES_OFFSET;
    const bytes = new Uint8Array(view.buffer, bytesStart, byteLen);
    const decoder = new TextDecoder('utf-8');
    return decoder.decode(bytes);
  }

  /**
   * Allocate a Text object in WASM memory from a JavaScript string.
   *
   * @param str - JavaScript string to store
   * @returns Pointer to OBJ_TEXT in WASM memory
   */
  allocText(str: string): Ptr32 {
    if (!this.exports) {
      throw new Error('No WASM module loaded');
    }

    const encoder = new TextEncoder();
    const bytes = encoder.encode(str);

    // Check if __alloc_text export exists
    const allocFn = this.exports['__alloc_text'];
    if (typeof allocFn !== 'function') {
      throw new Error('__alloc_text export not found - text allocation not supported by this module');
    }

    // Call WASM allocator: __alloc_text(byteLen) -> ptr
    const ptr = allocFn(bytes.length) as Ptr32;

    // Copy bytes to WASM memory at TEXT_BYTES_OFFSET
    const view = new Uint8Array(this.memory!.buffer, ptr + TEXT_BYTES_OFFSET, bytes.length);
    view.set(bytes);

    return ptr;
  }

  /**
   * Read raw bytes from memory.
   */
  getBytes(ptr: Ptr32, len: number): Uint8Array {
    if (!this.memory) {
      throw new Error('No WASM module loaded');
    }
    return new Uint8Array(this.memory.buffer, ptr, len);
  }

  /**
   * Read a foreign handle ID from a Foreign object.
   */
  getForeignHandle(ptr: Ptr32): number {
    const view = this.getMemoryView();
    return view.getUint32(ptr + FOREIGN_HANDLE_OFFSET, true);
  }

  /**
   * Get the JS value from a Foreign object.
   */
  getForeignValue(ptr: Ptr32): any {
    const handleId = this.getForeignHandle(ptr);
    return this.handles.get(handleId);
  }

  // ===========================================================================
  // Apply Protocol (for closures)
  // ===========================================================================

  /**
   * Get PAp metadata: expected arity, captured count, and ObjTag validation.
   */
  getPApInfo(closurePtr: Ptr32): { expectedArity: number; capturedCount: number; remainingArity: number } {
    const view = this.getMemoryView();

    // Read header to verify it's a PAp
    const header = view.getBigUint64(closurePtr, true);
    const objTag = Number((header >> HEADER_OBJTAG_SHIFT) & HEADER_OBJTAG_MASK);

    if (objTag !== OBJ_PAP) {
      const tagName = OBJ_TAG_NAMES[objTag as ObjTag] || `0x${objTag.toString(16)}`;
      throw new Error(`apply() requires a PAp closure, got ${tagName}`);
    }

    // Read arity fields
    const expectedArity = view.getUint16(closurePtr + PAP_EXPECTED_ARITY_OFFSET, true);
    const capturedCount = view.getUint16(closurePtr + PAP_CAPTURED_COUNT_OFFSET, true);
    const remainingArity = expectedArity - capturedCount;

    return { expectedArity, capturedCount, remainingArity };
  }

  /**
   * Read the TypeTags of captured arguments in a PAp.
   * Useful for debugging and validation.
   */
  getPApArgTypeTags(closurePtr: Ptr32): TypeTag[] {
    const view = this.getMemoryView();
    const { capturedCount } = this.getPApInfo(closurePtr);

    const tags: TypeTag[] = [];
    for (let i = 0; i < capturedCount; i++) {
      const slotOffset = closurePtr + PAP_ARGS_OFFSET + i * TYPED_SLOT_SIZE;
      const tag = view.getUint8(slotOffset + SLOT_TAG_OFFSET);
      tags.push(tag);
    }
    return tags;
  }

  /**
   * Apply a closure (PAp) to arguments.
   *
   * This reads the closure's arity and captured args, then calls the
   * appropriate __applyN function.
   *
   * @param closurePtr - Pointer to the PAp closure object
   * @param args - Arguments to apply (converted to i64)
   */
  apply(closurePtr: Ptr32, ...args: any[]): any {
    if (!this.exports) {
      throw new Error('No WASM module loaded');
    }

    // Validate the closure and get arity info
    const { remainingArity } = this.getPApInfo(closurePtr);

    // Validate argument count
    if (args.length > remainingArity) {
      throw new ArityError(remainingArity, args.length);
    }

    // Convert args to i64 values
    const i64Args = args.map((a) => {
      if (typeof a === 'bigint') return a;
      if (typeof a === 'number') return BigInt(a);
      if (typeof a === 'string') {
        // Allocate text and return pointer
        throw new Error('String args not yet supported in apply');
      }
      throw new Error(`Unsupported arg type: ${typeof a}`);
    });

    const arity = i64Args.length;
    const applyFn = this.exports[`__apply${arity}`];

    if (typeof applyFn !== 'function') {
      throw new Error(`__apply${arity} not exported (max supported arity may be lower)`);
    }

    // Call __applyN(closure_ptr, arg1, arg2, ...)
    return applyFn(closurePtr, ...i64Args);
  }

  /**
   * Apply a closure with TypeTag validation.
   *
   * Checks that each argument's TypeTag matches the expected type.
   * This provides runtime type safety for JS -> Unison calls.
   *
   * @param closurePtr - Pointer to the PAp closure
   * @param expectedTags - Array of expected TypeTags for the arguments
   * @param args - Arguments as TypedArg objects { tag, value }
   */
  applyTyped(
    closurePtr: Ptr32,
    args: Array<{ tag: TypeTag; value: bigint | number }>
  ): any {
    if (!this.exports) {
      throw new Error('No WASM module loaded');
    }

    // Validate the closure and get arity info
    const { remainingArity } = this.getPApInfo(closurePtr);

    if (args.length > remainingArity) {
      throw new ArityError(remainingArity, args.length);
    }

    // Validate TypeTags and convert to i64
    const i64Args: bigint[] = args.map((arg, i) => {
      // Validate TypeTag is a known value
      if (!this.isValidTypeTag(arg.tag)) {
        throw new Error(
          `Invalid TypeTag ${arg.tag} for argument ${i}`
        );
      }

      // Convert value based on TypeTag
      if (arg.tag === TYPE_FLOAT) {
        // Float: use raw i64 bit representation
        const f64Array = new Float64Array([Number(arg.value)]);
        const i64Array = new BigInt64Array(f64Array.buffer);
        // We know index 0 exists because we just created it with 1 element
        return i64Array[0]!;
      } else {
        // Nat, Int, Char, Boxed: use as i64
        return typeof arg.value === 'bigint' ? arg.value : BigInt(arg.value);
      }
    });

    const arity = i64Args.length;
    const applyFn = this.exports[`__apply${arity}`];

    if (typeof applyFn !== 'function') {
      throw new Error(`__apply${arity} not exported`);
    }

    return applyFn(closurePtr, ...i64Args);
  }

  /**
   * Check if a TypeTag is valid.
   */
  private isValidTypeTag(tag: TypeTag): boolean {
    return tag === TYPE_NAT ||
           tag === TYPE_INT ||
           tag === TYPE_FLOAT ||
           tag === TYPE_CHAR ||
           tag === TYPE_BOXED;
  }

  /**
   * Create a typed argument helper for Nat values.
   */
  static natArg(value: bigint | number): { tag: TypeTag; value: bigint } {
    return { tag: TYPE_NAT, value: typeof value === 'bigint' ? value : BigInt(value) };
  }

  /**
   * Create a typed argument helper for Int values.
   */
  static intArg(value: bigint | number): { tag: TypeTag; value: bigint } {
    return { tag: TYPE_INT, value: typeof value === 'bigint' ? value : BigInt(value) };
  }

  /**
   * Create a typed argument helper for Float values.
   */
  static floatArg(value: number): { tag: TypeTag; value: number } {
    return { tag: TYPE_FLOAT, value };
  }

  /**
   * Create a typed argument helper for Char values.
   */
  static charArg(char: string): { tag: TypeTag; value: bigint } {
    const codePoint = char.codePointAt(0) ?? 0;
    return { tag: TYPE_CHAR, value: BigInt(codePoint) };
  }

  /**
   * Create a typed argument helper for boxed (pointer) values.
   */
  static boxedArg(ptr: Ptr32): { tag: TypeTag; value: bigint } {
    return { tag: TYPE_BOXED, value: BigInt(ptr) };
  }

  // ===========================================================================
  // Debug Utilities
  // ===========================================================================

  /**
   * Dump heap state for debugging.
   */
  dumpHeap(): void {
    if (!this.memory) {
      console.log('No WASM module loaded');
      return;
    }
    console.log('=== Heap Dump ===');
    console.log(`Memory size: ${this.memory.buffer.byteLength} bytes`);
    console.log(`Foreign handles: ${this.handles.getAll().size}`);
    // Could add more detailed heap inspection here
  }

  /**
   * Inspect a value at a pointer.
   */
  inspectValue(ptr: Ptr32): object {
    const view = this.getMemoryView();
    const header = view.getBigUint64(ptr, true);
    const objTag = Number((header >> 20n) & 0xfffn);
    const size = Number(header & 0xfffffn);

    return {
      ptr: `0x${ptr.toString(16)}`,
      header: `0x${header.toString(16)}`,
      objTag,
      size,
    };
  }

  /**
   * Reset the runtime (clear handles, output, async state, etc.)
   */
  reset(): void {
    this.handles.clear();
    this.capturedOutput = [];
    this.asyncState = AsyncState.Idle;
    this.pendingContinuations.clear();
    this.resolveRun = null;
    this.rejectRun = null;
  }

  /**
   * Expose the runtime to browser dev tools for debugging.
   *
   * After calling this, you can access the runtime in the browser console:
   * ```javascript
   * unisonRuntime.dumpHeap()
   * unisonRuntime.inspectValue(0x4000)
   * unisonRuntime.call('calculatePrice', 5n)
   * ```
   *
   * @param name - Global variable name (default: 'unisonRuntime')
   */
  exposeToDevTools(name: string = 'unisonRuntime'): void {
    // Access window in a way that works for both browser and Node.js
    const globalObj = typeof window !== 'undefined' ? window : (typeof globalThis !== 'undefined' ? globalThis : {});

    (globalObj as Record<string, unknown>)[name] = {
      runtime: this,
      dumpHeap: () => this.dumpHeap(),
      inspectValue: (ptr: Ptr32) => this.inspectValue(ptr),
      handles: () => this.handles.getAll(),
      memory: () => this.memory,
      call: (funcName: string, ...args: any[]) => this.call(funcName, ...args),
      callBigInt: (funcName: string, ...args: any[]) => this.callBigInt(funcName, ...args),
      getText: (ptr: Ptr32) => this.getText(ptr),
      allocText: (str: string) => this.allocText(str),
      reset: () => this.reset(),
      asyncState: () => AsyncState[this.asyncState],
      pendingContinuations: () => this.pendingContinuations.size,
    };

    console.log(`🔧 Unison runtime exposed as window.${name}`);
  }

  /**
   * Get count of pending continuations (for testing).
   */
  getPendingContinuationCount(): number {
    return this.pendingContinuations.size;
  }
}

// =============================================================================
// Convenience Functions
// =============================================================================

/**
 * Create a new Unison runtime instance.
 */
export function createRuntime(): UnisonRuntime {
  return new UnisonRuntime();
}

/**
 * Load a WASM module and return the runtime.
 */
export async function loadUnisonWasm(
  wasmBytes: BufferSource,
  customImports: UnisonImports = {}
): Promise<UnisonRuntime> {
  const runtime = createRuntime();
  await runtime.loadWasm(wasmBytes, customImports);
  return runtime;
}
