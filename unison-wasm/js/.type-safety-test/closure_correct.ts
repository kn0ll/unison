
import { makeAdder, apply, Closure, Nat } from './mathlib.js';

const adder: Closure<[Nat], Nat> = makeAdder(10n);

// This should compile: correct types
const result: bigint = apply(adder, 5n);

// Type inference should work
const inferred = apply(adder, 15n);
const check: bigint = inferred;  // Should be bigint
