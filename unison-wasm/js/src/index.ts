/**
 * Unison WASM Runtime
 *
 * This module provides the JavaScript runtime for the Unison WASM backend.
 *
 * @module @unison/wasm-runtime
 */

// Re-export everything from submodules
export * from './abi-constants.js';
export * from './errors.js';
// Selective exports from continuation to avoid conflicts with errors.js
export {
  ContinuationHandle,
  AsyncState,
} from './continuation.js';
// Re-export the async error types from continuation.js (they have bigint contId)
export {
  ContinuationConsumedError as AsyncContinuationConsumedError,
  NestedAsyncError as AsyncNestedAsyncError,
  InvalidContinuationError as AsyncInvalidContinuationError,
  InvalidResumeError,
} from './continuation.js';
export * from './wasm-alloc.js';
export * from './wasm-debug.js';
export * from './runtime.js';
export type { FunctionSignatures } from './runtime.js';
export * from './ffi.js';
