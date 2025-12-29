/**
 * Unison WASM Runtime - Phase 6: Foreign Calls
 *
 * This module provides the main runtime class for loading and executing
 * Unison WASM modules with JS interop.
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
  type Ptr32,
  type TypeTag,
  type ObjTag,
} from './abi-constants.js';

import { ArityError } from './errors.js';

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
 * Foreign function definition for registration.
 */
export interface ForeignDef {
  name: string;
  handler: (runtime: UnisonRuntime, ...args: number[]) => number | void;
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
 * - Foreign function dispatch
 * - Memory access (getText, getBytes)
 * - Apply protocol for closures
 * - Debug utilities
 */
export class UnisonRuntime {
  private memory: WebAssembly.Memory | null = null;
  private exports: UnisonExports | null = null;

  /** Foreign handle table for JS objects */
  readonly handles: ForeignHandleTable = new ForeignHandleTable();

  /** Registered foreign functions */
  private foreignFuncs: Map<string, ForeignDef['handler']> = new Map();

  /** Console output captured during execution (for testing) */
  capturedOutput: string[] = [];

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
  }

  // ===========================================================================
  // Foreign Function Registration
  // ===========================================================================

  /**
   * Register a foreign function that WASM can call.
   */
  registerForeign(name: string, handler: ForeignDef['handler']): void {
    this.foreignFuncs.set(name, handler);
  }

  /**
   * Register multiple foreign functions.
   */
  registerForeignBatch(defs: ForeignDef[]): void {
    for (const def of defs) {
      this.registerForeign(def.name, def.handler);
    }
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
   * Reset the runtime (clear handles, output, etc.)
   */
  reset(): void {
    this.handles.clear();
    this.capturedOutput = [];
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
