{-# OPTIONS_GHC -Wno-incomplete-patterns #-}

-- | Haskell tests for ABI constants.
--
-- These tests verify that the Haskell ABI module matches the specification
-- in plans/WASM_ABI.md. The JavaScript tests verify round-trip allocation
-- and decoding; these tests verify the Haskell constants and encoding functions.
module Unison.Test.Wasm.ABI where

import Data.Bits ((.&.), shiftR)
import EasyTest
import Unison.Wasm.ABI

test :: Test ()
test =
  scope "wasm.abi" . tests $
    [ testTypeTags,
      testObjTags,
      testFrameTags,
      testSizes,
      testHeaderEncoding,
      testPackedTagEncoding,
      testAlignment,
      testSizeCalculations
    ]

-- -----------------------------------------------------------------------------
-- TypeTag Tests
-- -----------------------------------------------------------------------------

testTypeTags :: Test ()
testTypeTags =
  scope "typetag" . tests $
    [ scope "nat" $ expect (typeTagToWord8 typeNat == 0x00),
      scope "int" $ expect (typeTagToWord8 typeInt == 0x01),
      scope "float" $ expect (typeTagToWord8 typeFloat == 0x02),
      scope "char" $ expect (typeTagToWord8 typeChar == 0x03),
      scope "boxed" $ expect (typeTagToWord8 typeBoxed == 0x04),
      scope "fromWord8-valid" $ expect (typeTagFromWord8 0x02 == Just typeFloat),
      scope "fromWord8-invalid" $ expect (typeTagFromWord8 0x05 == Nothing)
    ]

-- -----------------------------------------------------------------------------
-- ObjTag Tests
-- -----------------------------------------------------------------------------

testObjTags :: Test ()
testObjTags =
  scope "objtag" . tests $
    [ scope "enum" $ expect (objTagToWord16 objEnum == 0x001),
      scope "data1" $ expect (objTagToWord16 objData1 == 0x002),
      scope "data2" $ expect (objTagToWord16 objData2 == 0x003),
      scope "dataG" $ expect (objTagToWord16 objDataG == 0x004),
      scope "pap" $ expect (objTagToWord16 objPAp == 0x005),
      scope "captured" $ expect (objTagToWord16 objCaptured == 0x006),
      scope "foreign" $ expect (objTagToWord16 objForeign == 0x007),
      scope "text" $ expect (objTagToWord16 objText == 0x008),
      scope "bytes" $ expect (objTagToWord16 objBytes == 0x009),
      scope "sequence" $ expect (objTagToWord16 objSequence == 0x00A),
      scope "fromWord16-valid" $ expect (objTagFromWord16 0x005 == Just objPAp),
      scope "fromWord16-invalid-zero" $ expect (objTagFromWord16 0x000 == Nothing),
      scope "fromWord16-invalid-high" $ expect (objTagFromWord16 0x00B == Nothing)
    ]

-- -----------------------------------------------------------------------------
-- FrameTag Tests
-- -----------------------------------------------------------------------------

testFrameTags :: Test ()
testFrameTags =
  scope "frametag" . tests $
    [ scope "ke" $ expect (frameTagToWord8 frameKE == 0x00),
      scope "push" $ expect (frameTagToWord8 framePush == 0x01),
      scope "mark" $ expect (frameTagToWord8 frameMark == 0x02),
      scope "fromWord8-valid" $ expect (frameTagFromWord8 0x01 == Just framePush),
      scope "fromWord8-invalid" $ expect (frameTagFromWord8 0x03 == Nothing)
    ]

-- -----------------------------------------------------------------------------
-- Size Tests
-- -----------------------------------------------------------------------------

testSizes :: Test ()
testSizes =
  scope "sizes" . tests $
    [ scope "typedSlot" $ expect (typedSlotSize == 16),
      scope "header" $ expect (headerSize == 8),
      scope "enum" $ expect (enumSize == 16),
      scope "data1" $ expect (data1Size == 32),
      scope "data2" $ expect (data2Size == 48),
      scope "pApBase" $ expect (pApBaseSize == 24),
      scope "capturedBase" $ expect (capturedBaseSize == 16),
      scope "foreign" $ expect (foreignSize == 16),
      scope "textBase" $ expect (textBaseSize == 16),
      scope "bytesBase" $ expect (bytesBaseSize == 16),
      scope "sequenceBase" $ expect (sequenceBaseSize == 16)
    ]

-- -----------------------------------------------------------------------------
-- Header Encoding Tests
-- -----------------------------------------------------------------------------

testHeaderEncoding :: Test ()
testHeaderEncoding =
  scope "header" . tests $
    [ scope "encode-decode-version" $ do
        let hdr = encodeHeader (HeaderFields 0 objEnum 0 16)
            decoded = decodeHeader hdr
        expect (hfVersion decoded == 0),
      scope "encode-decode-objTag" $ do
        let hdr = encodeHeader (HeaderFields 0 objData2 0 48)
            decoded = decodeHeader hdr
        expect (hfObjTag decoded == objData2),
      scope "encode-decode-size" $ do
        let hdr = encodeHeader (HeaderFields 0 objDataG 0 128)
            decoded = decodeHeader hdr
        expect (hfSize decoded == 128),
      scope "roundtrip-all-tags" $ do
        let tags =
              [ objEnum,
                objData1,
                objData2,
                objDataG,
                objPAp,
                objCaptured,
                objForeign,
                objText,
                objBytes,
                objSequence
              ]
            roundtrip tag =
              let hdr = encodeHeader (HeaderFields 0 tag 0 64)
                  decoded = decodeHeader hdr
               in hfObjTag decoded == tag
        expect (all roundtrip tags),
      scope "version-bits-in-correct-position" $ do
        -- Version 0xF should be in bits 60-63
        let hdr = encodeHeader (HeaderFields 0xF objEnum 0 0)
        expect ((hdr `shiftR` 60) .&. 0xF == 0xF),
      scope "size-in-low-32-bits" $ do
        let hdr = encodeHeader (HeaderFields 0 objEnum 0 0xDEADBEEF)
        expect (hdr .&. 0xFFFFFFFF == 0xDEADBEEF)
    ]

-- -----------------------------------------------------------------------------
-- Packed Tag Encoding Tests
-- -----------------------------------------------------------------------------

testPackedTagEncoding :: Test ()
testPackedTagEncoding =
  scope "packedtag" . tests $
    [ scope "encode-decode-typeRef" $ do
        let packed = encodePackedTag (PackedTagFields 0x12345678 0 0)
            decoded = decodePackedTag packed
        expect (ptTypeRef decoded == 0x12345678),
      scope "encode-decode-ctorId" $ do
        let packed = encodePackedTag (PackedTagFields 0 0xABCD 0)
            decoded = decodePackedTag packed
        expect (ptCtorId decoded == 0xABCD),
      scope "encode-decode-arity" $ do
        let packed = encodePackedTag (PackedTagFields 0 0 0x1234)
            decoded = decodePackedTag packed
        expect (ptArity decoded == 0x1234),
      scope "roundtrip-combined" $ do
        let packed = encodePackedTag (PackedTagFields 0xDEADBEEF 0x1234 0x0005)
            decoded = decodePackedTag packed
        expect
          ( ptTypeRef decoded == 0xDEADBEEF
              && ptCtorId decoded == 0x1234
              && ptArity decoded == 0x0005
          )
    ]

-- -----------------------------------------------------------------------------
-- Alignment Tests
-- -----------------------------------------------------------------------------

testAlignment :: Test ()
testAlignment =
  scope "align8" . tests $
    [ scope "0" $ expect (align8 0 == 0),
      scope "1" $ expect (align8 1 == 8),
      scope "7" $ expect (align8 7 == 8),
      scope "8" $ expect (align8 8 == 8),
      scope "9" $ expect (align8 9 == 16),
      scope "15" $ expect (align8 15 == 16),
      scope "16" $ expect (align8 16 == 16)
    ]

-- -----------------------------------------------------------------------------
-- Size Calculation Tests
-- -----------------------------------------------------------------------------

testSizeCalculations :: Test ()
testSizeCalculations =
  scope "sizeCalc" . tests $
    [ scope "dataG-0" $ expect (dataGSize 0 == 16),
      scope "dataG-1" $ expect (dataGSize 1 == 32),
      scope "dataG-2" $ expect (dataGSize 2 == 48),
      scope "dataG-3" $ expect (dataGSize 3 == 64),
      scope "pAp-0" $ expect (pApSize 0 == 24),
      scope "pAp-1" $ expect (pApSize 1 == 40),
      scope "pAp-2" $ expect (pApSize 2 == 56),
      scope "captured-0" $ expect (capturedSize 0 == 16),
      scope "captured-1" $ expect (capturedSize 1 == 32),
      scope "captured-2" $ expect (capturedSize 2 == 48),
      scope "text-0" $ expect (textSize 0 == 16),
      scope "text-1" $ expect (textSize 1 == 24),
      scope "text-8" $ expect (textSize 8 == 24),
      scope "text-9" $ expect (textSize 9 == 32),
      scope "bytes-0" $ expect (bytesSize 0 == 16),
      scope "bytes-1" $ expect (bytesSize 1 == 24),
      scope "bytes-9" $ expect (bytesSize 9 == 32),
      scope "sequence-0" $ expect (sequenceSize 0 == 16),
      scope "sequence-1" $ expect (sequenceSize 1 == 32),
      scope "sequence-2" $ expect (sequenceSize 2 == 48)
    ]
