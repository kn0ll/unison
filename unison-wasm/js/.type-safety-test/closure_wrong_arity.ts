
import { makeAdder, apply } from './mathlib.js';

const adder = makeAdder(10n);

// ERROR: Too many arguments
const result = apply(adder, 5n, 10n);  // Should error: expects 1 arg, got 2
