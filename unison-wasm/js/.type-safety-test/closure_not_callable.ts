
import { makeAdder, factorial, Closure, Nat } from './mathlib.js';

const adder: Closure<[Nat], Nat> = makeAdder(10n);

// ERROR: Cannot use closure directly as a function
const result = adder(5n);  // Should error: Closure is not callable
