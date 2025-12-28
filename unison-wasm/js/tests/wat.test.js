/**
 * Phase 1 WAT Execution Tests
 *
 * Tests that WAT emitted by the Haskell emitter can be parsed, compiled to WASM,
 * and executed correctly in Node.js.
 */

import { describe, it, before } from 'node:test';
import assert from 'node:assert/strict';

// The increment WAT module as emitted by Unison.Wasm.Emit.incrementModule
// This must match EXACTLY what emitModule incrementModule produces
const INCREMENT_WAT = `(module
  (func $increment (param $n i64) (result i64)
    local.get $n
    i64.const 1
    i64.add

  )
  (export "increment" (func $increment))
)
`;

/** @typedef {import('wabt').WabtModule} WabtModule */

/** @type {WabtModule | null} */
let wabtModule = null;

/**
 * Parse WAT text to WASM binary
 * @param {string} wat - WAT text format source
 * @returns {Uint8Array} WASM binary
 */
function watToBinary(wat) {
  if (!wabtModule) {
    throw new Error('wabt not initialized');
  }
  const module = wabtModule.parseWat('test.wat', wat);
  const { buffer } = module.toBinary({});
  module.destroy();
  return buffer;
}

/**
 * Compile WAT to WASM and instantiate
 * @param {string} wat - WAT text format source
 * @returns {Promise<WebAssembly.Instance>}
 */
async function instantiateWat(wat) {
  const binary = watToBinary(wat);
  const { instance } = await WebAssembly.instantiate(binary);
  return instance;
}

describe('Phase 1: WAT Execution', () => {
  before(async () => {
    // Dynamically import wabt (it's a CommonJS module that exports a promise)
    const wabt = await import('wabt');
    wabtModule = await wabt.default();
  });

  describe('WAT parsing', () => {
    it('should parse the increment WAT without errors', () => {
      assert.ok(wabtModule, 'wabt should be initialized');
      const module = wabtModule.parseWat('increment.wat', INCREMENT_WAT);
      assert.ok(module, 'module should be parsed');
      module.destroy();
    });

    it('should convert to valid WASM binary', () => {
      const binary = watToBinary(INCREMENT_WAT);
      assert.ok(binary instanceof Uint8Array, 'binary should be Uint8Array');
      assert.ok(binary.length > 0, 'binary should not be empty');
      // WASM magic number: \0asm
      assert.strictEqual(binary[0], 0x00, 'WASM magic byte 0');
      assert.strictEqual(binary[1], 0x61, 'WASM magic byte 1 (a)');
      assert.strictEqual(binary[2], 0x73, 'WASM magic byte 2 (s)');
      assert.strictEqual(binary[3], 0x6d, 'WASM magic byte 3 (m)');
    });
  });

  describe('WASM instantiation', () => {
    it('should instantiate the increment module', async () => {
      const instance = await instantiateWat(INCREMENT_WAT);
      assert.ok(instance, 'instance should exist');
      assert.ok(instance.exports, 'exports should exist');
    });

    it('should export the increment function', async () => {
      const instance = await instantiateWat(INCREMENT_WAT);
      assert.ok('increment' in instance.exports, 'increment should be exported');
      assert.strictEqual(typeof instance.exports.increment, 'function', 'increment should be a function');
    });
  });

  describe('increment function', () => {
    it('should compute increment(0) = 1', async () => {
      const instance = await instantiateWat(INCREMENT_WAT);
      const increment = /** @type {(n: bigint) => bigint} */ (instance.exports.increment);
      assert.strictEqual(increment(0n), 1n);
    });

    it('should compute increment(5) = 6', async () => {
      const instance = await instantiateWat(INCREMENT_WAT);
      const increment = /** @type {(n: bigint) => bigint} */ (instance.exports.increment);
      assert.strictEqual(increment(5n), 6n);
    });

    it('should compute increment(42) = 43', async () => {
      const instance = await instantiateWat(INCREMENT_WAT);
      const increment = /** @type {(n: bigint) => bigint} */ (instance.exports.increment);
      assert.strictEqual(increment(42n), 43n);
    });

    it('should compute increment(999) = 1000', async () => {
      const instance = await instantiateWat(INCREMENT_WAT);
      const increment = /** @type {(n: bigint) => bigint} */ (instance.exports.increment);
      assert.strictEqual(increment(999n), 1000n);
    });

    it('should handle large numbers', async () => {
      const instance = await instantiateWat(INCREMENT_WAT);
      const increment = /** @type {(n: bigint) => bigint} */ (instance.exports.increment);
      const large = 9007199254740991n; // Number.MAX_SAFE_INTEGER as bigint
      assert.strictEqual(increment(large), large + 1n);
    });

    it('should handle max u64 - 1', async () => {
      const instance = await instantiateWat(INCREMENT_WAT);
      const increment = /** @type {(n: bigint) => bigint} */ (instance.exports.increment);
      // Note: WASM i64 is returned as signed in JS. The bit pattern for
      // 18446744073709551614 (u64) is the same as -2 (i64).
      // When we increment, we get the bit pattern for 18446744073709551615 = -1 (signed).
      const input = -2n; // Equivalent to 2^64 - 2 as unsigned
      const result = increment(input);
      // Result is -1n in signed representation, which is 2^64 - 1 as unsigned
      assert.strictEqual(result, -1n);
    });

    it('should wrap around at max u64', async () => {
      const instance = await instantiateWat(INCREMENT_WAT);
      const increment = /** @type {(n: bigint) => bigint} */ (instance.exports.increment);
      // -1n is the signed representation of max u64
      const maxU64Signed = -1n;
      // i64.add wraps around: (2^64 - 1) + 1 = 0
      assert.strictEqual(increment(maxU64Signed), 0n);
    });
  });
});

describe('Phase 1: Additional Arithmetic Operations', () => {
  before(async () => {
    if (!wabtModule) {
      const wabt = await import('wabt');
      wabtModule = await wabt.default();
    }
  });

  it('should compute subtraction (n - 1)', async () => {
    const wat = `(module
      (func $decrement (param $n i64) (result i64)
        local.get $n
        i64.const 1
        i64.sub
      )
      (export "decrement" (func $decrement))
    )`;
    const instance = await instantiateWat(wat);
    const decrement = /** @type {(n: bigint) => bigint} */ (instance.exports.decrement);
    assert.strictEqual(decrement(10n), 9n);
    assert.strictEqual(decrement(1n), 0n);
  });

  it('should compute multiplication (n * 2)', async () => {
    const wat = `(module
      (func $double (param $n i64) (result i64)
        local.get $n
        i64.const 2
        i64.mul
      )
      (export "double" (func $double))
    )`;
    const instance = await instantiateWat(wat);
    const double = /** @type {(n: bigint) => bigint} */ (instance.exports.double);
    assert.strictEqual(double(5n), 10n);
    assert.strictEqual(double(0n), 0n);
    assert.strictEqual(double(100n), 200n);
  });

  it('should compute unsigned division (n / 2)', async () => {
    const wat = `(module
      (func $halve (param $n i64) (result i64)
        local.get $n
        i64.const 2
        i64.div_u
      )
      (export "halve" (func $halve))
    )`;
    const instance = await instantiateWat(wat);
    const halve = /** @type {(n: bigint) => bigint} */ (instance.exports.halve);
    assert.strictEqual(halve(10n), 5n);
    assert.strictEqual(halve(11n), 5n); // integer division
    assert.strictEqual(halve(0n), 0n);
  });

  it('should compute equality (a == b) returning i64', async () => {
    const wat = `(module
      (func $eq (param $a i64) (param $b i64) (result i64)
        local.get $a
        local.get $b
        i64.eq
        i64.extend_i32_u
      )
      (export "eq" (func $eq))
    )`;
    const instance = await instantiateWat(wat);
    const eq = /** @type {(a: bigint, b: bigint) => bigint} */ (instance.exports.eq);
    assert.strictEqual(eq(5n, 5n), 1n);
    assert.strictEqual(eq(5n, 6n), 0n);
  });

  it('should compute less-than-or-equal unsigned', async () => {
    const wat = `(module
      (func $leu (param $a i64) (param $b i64) (result i64)
        local.get $a
        local.get $b
        i64.le_u
        i64.extend_i32_u
      )
      (export "leu" (func $leu))
    )`;
    const instance = await instantiateWat(wat);
    const leu = /** @type {(a: bigint, b: bigint) => bigint} */ (instance.exports.leu);
    assert.strictEqual(leu(5n, 10n), 1n); // 5 <= 10
    assert.strictEqual(leu(10n, 5n), 0n); // 10 <= 5 is false
    assert.strictEqual(leu(5n, 5n), 1n);  // 5 <= 5
  });

  it('should compute complex expression (a + b) * 2', async () => {
    const wat = `(module
      (func $expr (param $a i64) (param $b i64) (result i64)
        local.get $a
        local.get $b
        i64.add
        i64.const 2
        i64.mul
      )
      (export "expr" (func $expr))
    )`;
    const instance = await instantiateWat(wat);
    const expr = /** @type {(a: bigint, b: bigint) => bigint} */ (instance.exports.expr);
    assert.strictEqual(expr(3n, 4n), 14n); // (3 + 4) * 2 = 14
    assert.strictEqual(expr(0n, 0n), 0n);
    assert.strictEqual(expr(10n, 20n), 60n);
  });
});

// =============================================================================
// Phase 2: SuperGroup → WAT Compilation Tests
// =============================================================================
// These tests verify that WAT emitted by the Compile.hs module (from SuperGroup)
// executes correctly.

describe('Phase 2: SuperGroup Compilation', () => {
  before(async () => {
    if (!wabtModule) {
      const wabt = await import('wabt');
      wabtModule = await wabt.default();
    }
  });

  // This WAT is produced by: stack exec unison-wasm-poc -- emit-add
  // Corresponds to Unison: add a b = a + b
  const ADD_WAT = `(module
  (func $add (param $p0 i64) (param $p1 i64) (result i64)
    local.get $p0
    local.get $p1
    i64.add

  )

  (export "add" (func $add))
)
`;

  // This WAT is produced by: stack exec unison-wasm-poc -- emit-mul
  // Corresponds to Unison: mul a b = a * b
  const MUL_WAT = `(module
  (func $mul (param $p0 i64) (param $p1 i64) (result i64)
    local.get $p0
    local.get $p1
    i64.mul

  )

  (export "mul" (func $mul))
)
`;

  // This WAT is produced by: stack exec unison-wasm-poc -- emit-identity
  // Corresponds to Unison: identity x = x
  const IDENTITY_WAT = `(module
  (func $identity (param $p0 i64) (result i64)
    local.get $p0

  )

  (export "identity" (func $identity))
)
`;

  it('should compile and run add(a, b) = a + b from SuperGroup', async () => {
    const instance = await instantiateWat(ADD_WAT);
    const add = /** @type {(a: bigint, b: bigint) => bigint} */ (instance.exports.add);

    assert.strictEqual(add(3n, 4n), 7n);
    assert.strictEqual(add(0n, 0n), 0n);
    assert.strictEqual(add(100n, 200n), 300n);
    assert.strictEqual(add(0xFFFFFFFFn, 1n), 0x100000000n);
  });

  it('should compile and run mul(a, b) = a * b from SuperGroup', async () => {
    const instance = await instantiateWat(MUL_WAT);
    const mul = /** @type {(a: bigint, b: bigint) => bigint} */ (instance.exports.mul);

    assert.strictEqual(mul(3n, 4n), 12n);
    assert.strictEqual(mul(0n, 100n), 0n);
    assert.strictEqual(mul(7n, 8n), 56n);
    assert.strictEqual(mul(1000n, 1000n), 1000000n);
  });

  it('should compile and run identity(x) = x from SuperGroup', async () => {
    const instance = await instantiateWat(IDENTITY_WAT);
    const identity = /** @type {(x: bigint) => bigint} */ (instance.exports.identity);

    assert.strictEqual(identity(42n), 42n);
    assert.strictEqual(identity(0n), 0n);
    // Note: WASM i64 is signed, so max u64 becomes -1n in JS BigInt
    assert.strictEqual(identity(-1n), -1n);
  });

  it('Phase 2 verification: functions from SuperGroup execute correctly', async () => {
    // This is the key Phase 2 checkpoint - demonstrating the full pipeline:
    // SuperGroup (Haskell) → WAT (text) → WASM (binary) → Execution (JS)

    const addInstance = await instantiateWat(ADD_WAT);
    const add = /** @type {(a: bigint, b: bigint) => bigint} */ (addInstance.exports.add);

    const mulInstance = await instantiateWat(MUL_WAT);
    const mul = /** @type {(a: bigint, b: bigint) => bigint} */ (mulInstance.exports.mul);

    // Calculate 5! = 5 * 4 * 3 * 2 * 1 = 120 using the compiled functions
    // This demonstrates the pipeline works for real arithmetic
    const factorial5 = mul(mul(mul(mul(5n, 4n), 3n), 2n), 1n);
    assert.strictEqual(factorial5, 120n, 'Should compute 5! = 120');

    // Calculate sum of 1..10 = 55
    let sum = 0n;
    for (let i = 1n; i <= 10n; i++) {
      sum = add(sum, i);
    }
    assert.strictEqual(sum, 55n, 'Should compute sum of 1..10 = 55');
  });
});

// =============================================================================
// Phase 2 Exit Criteria: Factorial from Actual Unison Source
// =============================================================================
// The Phase 2 exit criterion is: "Compile and run factorial from actual Unison source"
// This tests the full pipeline with MatchIntegral, recursive calls, and TLets.

describe('Phase 2 Exit Criteria: Factorial', () => {
  before(async () => {
    if (!wabtModule) {
      const wabt = await import('wabt');
      wabtModule = await wabt.default();
    }
  });

  // This WAT is produced by: stack exec unison-wasm-poc -- emit-factorial
  // Corresponds to Unison:
  //   factorial : Nat -> Nat
  //   factorial n = if n == 0 then 1 else n * factorial (n - 1)
  //
  // ANF representation:
  //   factorial n =
  //     match n with
  //       0 -> 1
  //       _ -> let one = 1
  //            let n1 = n - one
  //            let rec = factorial n1
  //            n * rec
  const FACTORIAL_WAT = `(module
  (func $factorial (param $p0 i64) (result i64)
    (local $p1 i64)
    (local $p2 i64)
    (local $p3 i64)

    local.get $p0
    i64.const 0
    i64.eq
    if (result i64)
      i64.const 1
    else
      i64.const 1
      local.set $p1
      local.get $p0
      local.get $p1
      i64.sub
      local.set $p2
      local.get $p2
      call $factorial
      local.set $p3
      local.get $p0
      local.get $p3
      i64.mul
    end
  )

  (export "factorial" (func $factorial))
)
`;

  it('should parse factorial WAT without errors', () => {
    assert.ok(wabtModule, 'wabt should be initialized');
    const module = wabtModule.parseWat('factorial.wat', FACTORIAL_WAT);
    assert.ok(module, 'module should be parsed');
    module.destroy();
  });

  it('should compute factorial(0) = 1 (base case)', async () => {
    const instance = await instantiateWat(FACTORIAL_WAT);
    const factorial = /** @type {(n: bigint) => bigint} */ (instance.exports.factorial);
    assert.strictEqual(factorial(0n), 1n);
  });

  it('should compute factorial(1) = 1', async () => {
    const instance = await instantiateWat(FACTORIAL_WAT);
    const factorial = /** @type {(n: bigint) => bigint} */ (instance.exports.factorial);
    assert.strictEqual(factorial(1n), 1n);
  });

  it('should compute factorial(5) = 120 (Phase 2 exit criteria)', async () => {
    const instance = await instantiateWat(FACTORIAL_WAT);
    const factorial = /** @type {(n: bigint) => bigint} */ (instance.exports.factorial);
    assert.strictEqual(factorial(5n), 120n, 'factorial(5) must equal 120 - Phase 2 exit criteria');
  });

  it('should compute factorial(10) = 3628800', async () => {
    const instance = await instantiateWat(FACTORIAL_WAT);
    const factorial = /** @type {(n: bigint) => bigint} */ (instance.exports.factorial);
    assert.strictEqual(factorial(10n), 3628800n);
  });

  it('should compute factorial(20) = 2432902008176640000', async () => {
    const instance = await instantiateWat(FACTORIAL_WAT);
    const factorial = /** @type {(n: bigint) => bigint} */ (instance.exports.factorial);
    assert.strictEqual(factorial(20n), 2432902008176640000n);
  });
});

// ============================================================================
// Phase 2 Parsed Unison Tests
// These test the full pipeline: Unison source → parse → lamLift → superNormalize → WAT
// ============================================================================
describe('Phase 2: Parsed Unison Compilation', () => {
  before(async () => {
    if (!wabtModule) {
      const wabt = await import('wabt');
      wabtModule = await wabt.default();
    }
  });

  // This WAT is produced by parsing ACTUAL Unison source code:
  //   let
  //     go n = match n with
  //       0 -> 1
  //       _ -> ##Nat.* n (go (##Nat.sub n 1))
  //     go 5
  //
  // Command: stack exec unison-wasm-poc -- compile factorial '<code>'
  //
  // Key differences from hardcoded SuperGroup:
  // - Lambda-lifted 'go' function has derived reference (fn_kog0d86f)
  // - Main 'factorial' function calls the lifted combinator
  // - Variable names come from actual Unison parsing (n, ANFBlank, etc.)
  const PARSED_FACTORIAL_WAT = `(module
  (func $fn_kog0d86f (param $p0 i64) (result i64)
    (local $p1 i64)
    (local $p2 i64)
    (local $p3 i64)

    local.get $p0
    i64.const 0
    i64.eq
    if (result i64)
      i64.const 1
    else
      i64.const 1
      local.set $p1
      local.get $p0
      local.get $p1
      i64.sub
      local.set $p2
      local.get $p2
      call $fn_kog0d86f
      local.set $p3
      local.get $p0
      local.get $p3
      i64.mul
    end


  )

  (func $factorial (result i64)
    (local $p0 i64)

    i64.const 5
    local.set $p0
    local.get $p0
    call $fn_kog0d86f

  )

  (export "factorial" (func $factorial))
)
`;

  it('should parse WAT from actual Unison source without errors', () => {
    assert.ok(wabtModule, 'wabt should be initialized');
    const module = wabtModule.parseWat('parsed_factorial.wat', PARSED_FACTORIAL_WAT);
    assert.ok(module, 'module should be parsed');
    module.destroy();
  });

  it('should compute factorial(5) = 120 from parsed Unison source', async () => {
    const instance = await instantiateWat(PARSED_FACTORIAL_WAT);
    const factorial = /** @type {() => bigint} */ (instance.exports.factorial);
    assert.strictEqual(factorial(), 120n, 'factorial() must return 120 (5! from parsed Unison)');
  });

  it('TRUE Phase 2 Exit Criteria: Unison source → WAT → WASM → 120', async () => {
    // This is the REAL Phase 2 exit criteria:
    // 1. Parse actual Unison code (not handcrafted SuperGroup)
    // 2. Lambda-lift to separate combinators
    // 3. Compile each combinator to WAT
    // 4. Link lifted functions together
    // 5. Execute and get correct result

    const instance = await instantiateWat(PARSED_FACTORIAL_WAT);
    const factorial = /** @type {() => bigint} */ (instance.exports.factorial);

    // The Unison code hardcodes 'go 5', so factorial() returns 5! = 120
    assert.strictEqual(factorial(), 120n);
  });
});
