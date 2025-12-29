/**
 * Tests for the UnisonRuntime class
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { ForeignHandleTable, createRuntime, loadUnisonWasm, UnisonRuntime } from '../runtime.js';
import { TYPE_NAT, TYPE_INT, TYPE_FLOAT, TYPE_CHAR, TYPE_BOXED } from '../abi-constants.js';

describe('ForeignHandleTable', () => {
  it('allocates handles starting from 1', () => {
    const table = new ForeignHandleTable();
    const id1 = table.alloc('hello');
    const id2 = table.alloc('world');
    assert.equal(id1, 1);
    assert.equal(id2, 2);
  });

  it('retrieves values by handle', () => {
    const table = new ForeignHandleTable();
    const obj = { name: 'test' };
    const id = table.alloc(obj);
    assert.equal(table.get(id), obj);
  });

  it('returns null for handle 0', () => {
    const table = new ForeignHandleTable();
    assert.equal(table.get(0), null);
  });

  it('throws for invalid handles', () => {
    const table = new ForeignHandleTable();
    assert.throws(() => table.get(999), /Invalid foreign handle/);
  });

  it('frees handles', () => {
    const table = new ForeignHandleTable();
    const id = table.alloc('temp');
    table.free(id);
    assert.throws(() => table.get(id), /Invalid foreign handle/);
  });

  it('clears all handles', () => {
    const table = new ForeignHandleTable();
    table.alloc('a');
    table.alloc('b');
    table.clear();
    assert.equal(table.getAll().size, 0);
  });
});

describe('UnisonRuntime', () => {
  describe('creation', () => {
    it('creates a runtime with empty state', () => {
      const runtime = createRuntime();
      assert.equal(runtime.capturedOutput.length, 0);
    });
  });

  describe('foreign function registration', () => {
    it('registers foreign functions', () => {
      const runtime = createRuntime();
      runtime.registerForeign('myFunc', () => {
        return 42;
      });
      // Can't directly test without loading WASM, but registration should not throw
      assert.ok(true);
    });
  });

  describe('loading WASM', () => {
    it('throws when calling without module loaded', () => {
      const runtime = createRuntime();
      assert.throws(() => runtime.call('answer'), /No WASM module loaded/);
    });
  });

  describe('reset', () => {
    it('clears captured output and handles', () => {
      const runtime = createRuntime();
      runtime.capturedOutput.push('test');
      runtime.handles.alloc('value');
      runtime.reset();
      assert.equal(runtime.capturedOutput.length, 0);
      assert.equal(runtime.handles.getAll().size, 0);
    });
  });
});

describe('loadUnisonWasm helper', () => {
  it('is exported and callable', () => {
    // Just verify the function exists
    assert.equal(typeof loadUnisonWasm, 'function');
  });
});

describe('Typed argument helpers', () => {
  it('natArg creates TypeTag and value', () => {
    const arg = UnisonRuntime.natArg(42);
    assert.equal(arg.tag, TYPE_NAT);
    assert.equal(arg.value, 42n);
  });

  it('natArg handles bigint input', () => {
    const arg = UnisonRuntime.natArg(12345678901234567890n);
    assert.equal(arg.tag, TYPE_NAT);
    assert.equal(arg.value, 12345678901234567890n);
  });

  it('intArg creates Int TypeTag', () => {
    const arg = UnisonRuntime.intArg(-42);
    assert.equal(arg.tag, TYPE_INT);
    assert.equal(arg.value, -42n);
  });

  it('floatArg creates Float TypeTag', () => {
    const arg = UnisonRuntime.floatArg(3.14);
    assert.equal(arg.tag, TYPE_FLOAT);
    assert.equal(arg.value, 3.14);
  });

  it('charArg creates Char TypeTag with codepoint', () => {
    const arg = UnisonRuntime.charArg('A');
    assert.equal(arg.tag, TYPE_CHAR);
    assert.equal(arg.value, 65n); // ASCII 'A'
  });

  it('charArg handles unicode', () => {
    const arg = UnisonRuntime.charArg('😀');
    assert.equal(arg.tag, TYPE_CHAR);
    assert.equal(arg.value, 128512n); // U+1F600
  });

  it('boxedArg creates Boxed TypeTag', () => {
    const arg = UnisonRuntime.boxedArg(0x4000);
    assert.equal(arg.tag, TYPE_BOXED);
    assert.equal(arg.value, BigInt(0x4000));
  });
});

describe('UnisonRuntime (no WASM)', () => {
  it('apply throws without WASM module', () => {
    const runtime = createRuntime();
    assert.throws(() => runtime.apply(0x4000, 1n), /No WASM module loaded/);
  });

  it('applyTyped throws without WASM module', () => {
    const runtime = createRuntime();
    assert.throws(
      () => runtime.applyTyped(0x4000, [UnisonRuntime.natArg(42)]),
      /No WASM module loaded/
    );
  });

  it('getPApInfo throws without WASM module', () => {
    const runtime = createRuntime();
    assert.throws(() => runtime.getPApInfo(0x4000), /No WASM module loaded/);
  });
});

