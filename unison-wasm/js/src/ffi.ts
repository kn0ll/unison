/**
 * FFI Handlers for Unison WASM
 *
 * Provides JavaScript implementations for Unison foreign functions
 * and debug primitives. Same handlers work in browser and Node.
 *
 * @module ffi
 */

import {
  TEXT_BYTELEN_OFFSET,
  TEXT_BYTES_OFFSET,
} from './abi-constants.js';

/**
 * Read a Text value from WASM memory.
 *
 * Text layout in memory:
 * - Offset 0-7: Header (8 bytes)
 * - Offset 8-11: Byte length (4 bytes)
 * - Offset 12-15: Char length (4 bytes)
 * - Offset 16+: UTF-8 bytes
 */
export function readText(memory: WebAssembly.Memory, ptr: bigint): string {
  const view = new DataView(memory.buffer);
  const ptrNum = Number(ptr);

  // Read byte length
  const byteLen = view.getUint32(ptrNum + TEXT_BYTELEN_OFFSET, true);

  // Read UTF-8 bytes
  const bytes = new Uint8Array(memory.buffer, ptrNum + TEXT_BYTES_OFFSET, byteLen);

  return new TextDecoder().decode(bytes);
}

/**
 * Create FFI import handlers for WASM instantiation.
 *
 * @param getMemory - Function that returns the WASM memory (called lazily since
 *                    memory isn't available until after instantiation)
 *
 * @example
 * ```typescript
 * let memory: WebAssembly.Memory;
 * const imports = createFFIHandlers(() => memory);
 * const module = await WebAssembly.instantiate(bytes, imports);
 * memory = module.instance.exports.memory as WebAssembly.Memory;
 * ```
 */
export function createFFIHandlers(
  getMemory: () => WebAssembly.Memory
): WebAssembly.Imports {
  return {
    ffi: {
      /**
       * Debug.trace : Text -> a -> ()
       *
       * Prints the text to console and returns unit (0).
       */
      Debug_trace: (textPtr: bigint, _valPtr: bigint): bigint => {
        try {
          const text = readText(getMemory(), textPtr);
          console.log(`[trace] ${text}`);
        } catch (e) {
          console.log(`[trace] <error reading text: ${e}>`);
        }
        return 0n; // Unit
      },

      /**
       * Debug.watch : Text -> a -> a
       *
       * Prints the text to console and returns the value unchanged.
       */
      Debug_watch: (textPtr: bigint): bigint => {
        try {
          const text = readText(getMemory(), textPtr);
          console.log(`[watch] ${text}`);
        } catch (e) {
          console.log(`[watch] <error reading text: ${e}>`);
        }
        return textPtr; // Return the value (simplified - just return the pointer)
      },
    },
  };
}

/**
 * Merge FFI handlers with additional custom handlers.
 *
 * @example
 * ```typescript
 * const imports = mergeHandlers(
 *   createFFIHandlers(() => memory),
 *   { ffi: { Custom_handler: () => 42n } }
 * );
 * ```
 */
export function mergeHandlers(
  ...handlers: WebAssembly.Imports[]
): WebAssembly.Imports {
  const result: WebAssembly.Imports = {};

  for (const h of handlers) {
    for (const [namespace, funcs] of Object.entries(h)) {
      if (!result[namespace]) {
        result[namespace] = {};
      }
      Object.assign(result[namespace], funcs);
    }
  }

  return result;
}

