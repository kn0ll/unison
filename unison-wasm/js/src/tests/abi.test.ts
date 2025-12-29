/**
 * ABI Conformance Tests for Unison WASM Backend
 *
 * These tests verify that the JS runtime correctly implements the ABI
 * specified in unison-wasm/docs/ABI.md.
 *
 * These tests must stay in sync with the Haskell ABI constants in
 * Unison.Wasm.ABI and the TypeScript constants in abi-constants.ts.
 */

import { describe, it, before } from 'node:test';
import assert from 'node:assert/strict';

import {
  // TypeTag constants
  TYPE_NAT,
  TYPE_INT,
  TYPE_FLOAT,
  TYPE_CHAR,
  TYPE_BOXED,

  // ObjTag constants
  OBJ_ENUM,
  OBJ_DATA1,
  OBJ_DATA2,
  OBJ_DATAG,
  OBJ_PAP,
  OBJ_CAPTURED,
  OBJ_FOREIGN,
  OBJ_TEXT,
  OBJ_BYTES,
  OBJ_SEQUENCE,

  // FrameTag constants
  FRAME_KE,
  FRAME_PUSH,
  FRAME_MARK,

  // Size constants
  TYPED_SLOT_SIZE,
  HEADER_SIZE,
  ENUM_SIZE,
  DATA1_SIZE,
  DATA2_SIZE,

  // Helper functions
  encodeHeader,
  decodeHeader,
  encodePackedTag,
  decodePackedTag,
  align8,
  dataGObjectSize,
  papObjectSize,
  capturedObjectSize,
  textObjectSize,
  bytesObjectSize,
  sequenceObjectSize,

  // Allocator
  createHeapAllocator,
  heapAlloc,
  writeTypedSlot,
  readTypedSlot,
  allocEnum,
  allocData1,
  allocData2,
  allocDataG,
  allocPAp,
  allocForeign,
  allocText,
  allocBytes,
  allocSequence,
  natSlot,
  charSlot,
  boxedSlot,

  // Debug
  decodeObject,
  formatObject,
  hexDump,
} from '../index.js';

import type { HeapAllocator } from '../wasm-alloc.js';
import type {
  DecodedDataData,
  DecodedPApData,
  DecodedForeignData,
  DecodedTextData,
  DecodedBytesData,
  DecodedSequenceData,
  DecodedEnumData,
} from '../wasm-debug.js';

// Test allocator
let alloc: HeapAllocator;

function resetMemory(): void {
  alloc = createHeapAllocator(1024 * 1024); // 1MB for tests
}

// =============================================================================
// ABI Constants Tests
// =============================================================================

describe('ABI Constants', () => {
  it('TypeTag values match spec', () => {
    assert.equal(TYPE_NAT, 0x00);
    assert.equal(TYPE_INT, 0x01);
    assert.equal(TYPE_FLOAT, 0x02);
    assert.equal(TYPE_CHAR, 0x03);
    assert.equal(TYPE_BOXED, 0x04);
  });

  it('ObjTag values match spec', () => {
    assert.equal(OBJ_ENUM, 0x001);
    assert.equal(OBJ_DATA1, 0x002);
    assert.equal(OBJ_DATA2, 0x003);
    assert.equal(OBJ_DATAG, 0x004);
    assert.equal(OBJ_PAP, 0x005);
    assert.equal(OBJ_CAPTURED, 0x006);
    assert.equal(OBJ_FOREIGN, 0x007);
    assert.equal(OBJ_TEXT, 0x008);
    assert.equal(OBJ_BYTES, 0x009);
    assert.equal(OBJ_SEQUENCE, 0x00A);
  });

  it('FrameTag values match spec', () => {
    assert.equal(FRAME_KE, 0x00);
    assert.equal(FRAME_PUSH, 0x01);
    assert.equal(FRAME_MARK, 0x02);
  });

  it('TypedSlot size is 16 bytes', () => {
    assert.equal(TYPED_SLOT_SIZE, 16);
  });

  it('Header size is 8 bytes', () => {
    assert.equal(HEADER_SIZE, 8);
  });
});

// =============================================================================
// Header Encoding Tests
// =============================================================================

describe('Header Encoding', () => {
  it('encodes and decodes version correctly', () => {
    const header = encodeHeader(0, OBJ_ENUM, 16);
    const decoded = decodeHeader(header);
    assert.equal(decoded.version, 0);
  });

  it('encodes and decodes objTag correctly', () => {
    const header = encodeHeader(0, OBJ_DATA2, 48);
    const decoded = decodeHeader(header);
    assert.equal(decoded.objTag, OBJ_DATA2);
  });

  it('encodes and decodes size correctly', () => {
    const header = encodeHeader(0, OBJ_DATAG, 128);
    const decoded = decodeHeader(header);
    assert.equal(decoded.size, 128);
  });

  it('round-trips all ObjTag values', () => {
    const tags = [
      OBJ_ENUM, OBJ_DATA1, OBJ_DATA2, OBJ_DATAG,
      OBJ_PAP, OBJ_CAPTURED, OBJ_FOREIGN,
      OBJ_TEXT, OBJ_BYTES, OBJ_SEQUENCE,
    ];

    for (const tag of tags) {
      const header = encodeHeader(0, tag, 64);
      const decoded = decodeHeader(header);
      assert.equal(decoded.objTag, tag, `ObjTag ${tag} failed round-trip`);
    }
  });
});

// =============================================================================
// Packed Tag Encoding Tests
// =============================================================================

describe('Packed Tag Encoding', () => {
  it('encodes and decodes rTag correctly', () => {
    const packed = encodePackedTag(0x1234, 0);
    const decoded = decodePackedTag(packed);
    assert.equal(decoded.rTag, 0x1234);
  });

  it('encodes and decodes cTag correctly', () => {
    const packed = encodePackedTag(0, 0xABCD);
    const decoded = decodePackedTag(packed);
    assert.equal(decoded.cTag, 0xABCD);
  });

  it('round-trips combined values', () => {
    const packed = encodePackedTag(0x1234, 0xABCD);
    const decoded = decodePackedTag(packed);
    assert.equal(decoded.rTag, 0x1234);
    assert.equal(decoded.cTag, 0xABCD);
  });
});

// =============================================================================
// Alignment Tests
// =============================================================================

describe('Alignment', () => {
  it('align8 rounds up correctly', () => {
    assert.equal(align8(0), 0);
    assert.equal(align8(1), 8);
    assert.equal(align8(7), 8);
    assert.equal(align8(8), 8);
    assert.equal(align8(9), 16);
    assert.equal(align8(15), 16);
    assert.equal(align8(16), 16);
  });
});

// =============================================================================
// Size Calculation Tests
// =============================================================================

describe('Size Calculations', () => {
  it('Enum size is 16 bytes', () => {
    assert.equal(ENUM_SIZE, 16);
  });

  it('Data1 size is 32 bytes', () => {
    assert.equal(DATA1_SIZE, 32);
  });

  it('Data2 size is 48 bytes', () => {
    assert.equal(DATA2_SIZE, 48);
  });

  it('DataG size scales with arity', () => {
    assert.equal(dataGObjectSize(0), 16);
    assert.equal(dataGObjectSize(1), 32);
    assert.equal(dataGObjectSize(2), 48);
    assert.equal(dataGObjectSize(3), 64);
  });

  it('PAp size scales with captured count', () => {
    assert.equal(papObjectSize(0), 24);
    assert.equal(papObjectSize(1), 40);
    assert.equal(papObjectSize(2), 56);
  });

  it('Captured size scales with slot count', () => {
    assert.equal(capturedObjectSize(0), 16);
    assert.equal(capturedObjectSize(1), 32);
    assert.equal(capturedObjectSize(2), 48);
  });

  it('Text size is aligned to 8 bytes', () => {
    assert.equal(textObjectSize(0), 16);
    assert.equal(textObjectSize(1), 24);
    assert.equal(textObjectSize(8), 24);
    assert.equal(textObjectSize(9), 32);
  });

  it('Bytes size is aligned to 8 bytes', () => {
    assert.equal(bytesObjectSize(0), 16);
    assert.equal(bytesObjectSize(1), 24);
    assert.equal(bytesObjectSize(8), 24);
    assert.equal(bytesObjectSize(9), 32);
  });

  it('Sequence size scales with element count', () => {
    assert.equal(sequenceObjectSize(0), 16);
    assert.equal(sequenceObjectSize(1), 32);
    assert.equal(sequenceObjectSize(2), 48);
  });
});

// =============================================================================
// TypedSlot Tests
// =============================================================================

describe('TypedSlot', () => {
  before(() => {
    resetMemory();
  });

  it('writes and reads Nat correctly', () => {
    const ptr = heapAlloc(alloc, TYPED_SLOT_SIZE);
    writeTypedSlot(alloc.view, ptr, natSlot(42n));
    const slot = readTypedSlot(alloc.view, ptr);
    assert.equal(slot.tag, TYPE_NAT);
    assert.equal(slot.payload, 42n);
  });

  it('writes and reads Char correctly', () => {
    const ptr = heapAlloc(alloc, TYPED_SLOT_SIZE);
    writeTypedSlot(alloc.view, ptr, charSlot('😀')); // U+1F600
    const slot = readTypedSlot(alloc.view, ptr);
    assert.equal(slot.tag, TYPE_CHAR);
    assert.equal(Number(slot.payload), 0x1F600);
  });

  it('writes and reads Boxed correctly', () => {
    const ptr = heapAlloc(alloc, TYPED_SLOT_SIZE);
    writeTypedSlot(alloc.view, ptr, boxedSlot(0x1000));
    const slot = readTypedSlot(alloc.view, ptr);
    assert.equal(slot.tag, TYPE_BOXED);
    assert.equal(Number(slot.payload), 0x1000);
  });
});

// =============================================================================
// Enum Allocation Tests
// =============================================================================

describe('Enum Allocation', () => {
  before(() => {
    resetMemory();
  });

  it('allocates with correct ObjTag', () => {
    const ptr = allocEnum(alloc, 0x100, 0);
    const obj = decodeObject(alloc.view, ptr);
    assert.equal(obj.objTag, OBJ_ENUM);
  });

  it('stores typeRef correctly', () => {
    const ptr = allocEnum(alloc, 0xDEADBEEF, 0);
    const obj = decodeObject(alloc.view, ptr);
    const data = obj.data as DecodedEnumData;
    assert.equal(data.typeRef, 0xDEADBEEF);
  });

  it('is 8-byte aligned', () => {
    const ptr = allocEnum(alloc, 0x100, 0);
    assert.equal(ptr % 8, 0);
  });
});

// =============================================================================
// Data1 Allocation Tests
// =============================================================================

describe('Data1 Allocation', () => {
  before(() => {
    resetMemory();
  });

  it('allocates with correct ObjTag', () => {
    const ptr = allocData1(alloc, 0x100, 0, natSlot(1n));
    const obj = decodeObject(alloc.view, ptr);
    assert.equal(obj.objTag, OBJ_DATA1);
  });

  it('stores field0 correctly', () => {
    const ptr = allocData1(alloc, 0x100, 0, natSlot(42n));
    const obj = decodeObject(alloc.view, ptr);
    const data = obj.data as DecodedDataData;
    assert.ok(data.fields);
    assert.equal(data.fields.length, 1);
    assert.equal(data.fields[0]?.tag, TYPE_NAT);
    assert.equal(data.fields[0]?.payload, 42n);
  });
});

// =============================================================================
// Data2 Allocation Tests
// =============================================================================

describe('Data2 Allocation', () => {
  before(() => {
    resetMemory();
  });

  it('allocates with correct ObjTag', () => {
    const ptr = allocData2(alloc, 0x100, 0, natSlot(1n), natSlot(2n));
    const obj = decodeObject(alloc.view, ptr);
    assert.equal(obj.objTag, OBJ_DATA2);
  });

  it('stores both fields correctly', () => {
    const ptr = allocData2(alloc, 0x100, 0, natSlot(10n), natSlot(20n));
    const obj = decodeObject(alloc.view, ptr);
    const data = obj.data as DecodedDataData;
    assert.ok(data.fields);
    assert.equal(data.fields.length, 2);
    assert.equal(data.fields[0]?.payload, 10n);
    assert.equal(data.fields[1]?.payload, 20n);
  });
});

// =============================================================================
// DataG Allocation Tests
// =============================================================================

describe('DataG Allocation', () => {
  before(() => {
    resetMemory();
  });

  it('allocates with correct ObjTag', () => {
    const ptr = allocDataG(alloc, 0x100, 0, [natSlot(1n)]);
    const obj = decodeObject(alloc.view, ptr);
    assert.equal(obj.objTag, OBJ_DATAG);
  });

  it('stores all fields correctly', () => {
    const fields = [natSlot(10n), natSlot(20n), natSlot(30n)];
    const ptr = allocDataG(alloc, 0x100, 0, fields);
    const obj = decodeObject(alloc.view, ptr);
    const data = obj.data as DecodedDataData;
    assert.ok(data.fields);
    assert.equal(data.fields.length, 3);
    assert.equal(data.fields[0]?.payload, 10n);
    assert.equal(data.fields[1]?.payload, 20n);
    assert.equal(data.fields[2]?.payload, 30n);
  });
});

// =============================================================================
// PAp Allocation Tests
// =============================================================================

describe('PAp Allocation', () => {
  before(() => {
    resetMemory();
  });

  it('allocates with correct ObjTag', () => {
    const ptr = allocPAp(alloc, 0x1000, 0, 3, []);
    const obj = decodeObject(alloc.view, ptr);
    assert.equal(obj.objTag, OBJ_PAP);
  });

  it('stores captured args correctly', () => {
    const args = [natSlot(100n), natSlot(200n)];
    const ptr = allocPAp(alloc, 0x1000, 0, 3, args);
    const obj = decodeObject(alloc.view, ptr);
    const data = obj.data as DecodedPApData;
    assert.ok(data.args);
    assert.equal(data.args.length, 2);
  });
});

// =============================================================================
// Foreign Allocation Tests
// =============================================================================

describe('Foreign Allocation', () => {
  before(() => {
    resetMemory();
  });

  it('allocates with correct ObjTag', () => {
    const ptr = allocForeign(alloc, 1);
    const obj = decodeObject(alloc.view, ptr);
    assert.equal(obj.objTag, OBJ_FOREIGN);
  });

  it('stores handleId correctly', () => {
    const ptr = allocForeign(alloc, 0x12345678);
    const obj = decodeObject(alloc.view, ptr);
    const data = obj.data as DecodedForeignData;
    assert.equal(data.handleId, 0x12345678);
  });
});

// =============================================================================
// Text Allocation Tests
// =============================================================================

describe('Text Allocation', () => {
  before(() => {
    resetMemory();
  });

  it('allocates with correct ObjTag', () => {
    const ptr = allocText(alloc, 'hello');
    const obj = decodeObject(alloc.view, ptr);
    assert.equal(obj.objTag, OBJ_TEXT);
  });

  it('stores UTF-8 data correctly', () => {
    const ptr = allocText(alloc, 'hello');
    const obj = decodeObject(alloc.view, ptr);
    const data = obj.data as DecodedTextData;
    assert.equal(data.content, 'hello');
  });

  it('handles Unicode correctly', () => {
    const ptr = allocText(alloc, '你好');
    const obj = decodeObject(alloc.view, ptr);
    const data = obj.data as DecodedTextData;
    assert.equal(data.content, '你好');
  });
});

// =============================================================================
// Bytes Allocation Tests
// =============================================================================

describe('Bytes Allocation', () => {
  before(() => {
    resetMemory();
  });

  it('allocates with correct ObjTag', () => {
    const ptr = allocBytes(alloc, new Uint8Array([1, 2, 3]));
    const obj = decodeObject(alloc.view, ptr);
    assert.equal(obj.objTag, OBJ_BYTES);
  });

  it('stores data correctly', () => {
    const data = new Uint8Array([0xDE, 0xAD, 0xBE, 0xEF]);
    const ptr = allocBytes(alloc, data);
    const obj = decodeObject(alloc.view, ptr);
    const objData = obj.data as DecodedBytesData;
    assert.deepEqual(objData.bytes, [0xDE, 0xAD, 0xBE, 0xEF]);
  });
});

// =============================================================================
// Sequence Allocation Tests
// =============================================================================

describe('Sequence Allocation', () => {
  before(() => {
    resetMemory();
  });

  it('allocates with correct ObjTag', () => {
    const ptr = allocSequence(alloc, [natSlot(1n)]);
    const obj = decodeObject(alloc.view, ptr);
    assert.equal(obj.objTag, OBJ_SEQUENCE);
  });

  it('stores elements correctly', () => {
    const elements = [natSlot(10n), natSlot(20n), natSlot(30n)];
    const ptr = allocSequence(alloc, elements);
    const obj = decodeObject(alloc.view, ptr);
    const data = obj.data as DecodedSequenceData;
    assert.ok(data.elements);
    assert.equal(data.elements.length, 3);
  });
});

// =============================================================================
// Memory Inspector Tests
// =============================================================================

describe('Memory Inspector', () => {
  before(() => {
    resetMemory();
  });

  it('formatObject produces readable output', () => {
    const ptr = allocEnum(alloc, 0x1, 0);
    const obj = decodeObject(alloc.view, ptr);
    const formatted = formatObject(obj);
    assert.ok(formatted.includes('Enum') || formatted.includes('OBJ_ENUM'));
  });

  it('hexDump produces output', () => {
    const ptr = heapAlloc(alloc, 32);
    const dump = hexDump(alloc.view, ptr, 32);
    assert.ok(dump.length > 0);
  });
});

// =============================================================================
// Integration Tests: Complex Object Graphs
// =============================================================================

describe('Complex Object Graphs', () => {
  before(() => {
    resetMemory();
  });

  it('allocates nested Data structures', () => {
    // Create: Some(Some(42))
    const TYPE_REF_OPTIONAL = 0x0002;
    const CTOR_SOME = 1;

    const inner = allocData1(alloc, TYPE_REF_OPTIONAL, CTOR_SOME, natSlot(42n));
    const outer = allocData1(alloc, TYPE_REF_OPTIONAL, CTOR_SOME, boxedSlot(inner));

    const outerObj = decodeObject(alloc.view, outer);
    assert.equal(outerObj.objTag, OBJ_DATA1);
    const outerData = outerObj.data as DecodedDataData;
    assert.equal(outerData.fields[0]?.tag, TYPE_BOXED);

    const innerPtr = outerData.fields[0]?.payload;
    assert.ok(innerPtr !== undefined);
    const innerObj = decodeObject(alloc.view, Number(innerPtr));
    assert.equal(innerObj.objTag, OBJ_DATA1);
    const innerData = innerObj.data as DecodedDataData;
    assert.equal(innerData.fields[0]?.payload, 42n);
  });

  it('allocates PAp with boxed args', () => {
    const enum1 = allocEnum(alloc, 0x1, 0);
    const enum2 = allocEnum(alloc, 0x1, 1);

    const pap = allocPAp(alloc, 0x5000, 0, 3, [boxedSlot(enum1), boxedSlot(enum2)]);
    const obj = decodeObject(alloc.view, pap);

    assert.equal(obj.objTag, OBJ_PAP);
    const data = obj.data as DecodedPApData;

    // Verify the captured args point to valid objects
    const arg0Ptr = data.args[0]?.payload;
    assert.ok(arg0Ptr !== undefined);
    const arg0Obj = decodeObject(alloc.view, Number(arg0Ptr));
    assert.equal(arg0Obj.objTag, OBJ_ENUM);
  });
});
