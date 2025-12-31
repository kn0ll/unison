-- | Literal value compilation.
--
-- This module compiles Unison literal values to WASM instructions:
-- * Nat, Int: i64 constants
-- * Float: f64 reinterpreted as i64
-- * Char: Unicode codepoint as i64
-- * Text: Heap-allocated UTF-8 string
module Unison.Wasm.Compile.Literal
  ( compileLit,
    compileTextLit,
    LiteralError (..),
  )
where

import Data.ByteString qualified as BS
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.Word (Word8, Word32)
import Unison.Reference (Reference)
import Unison.Runtime.ANF (Lit (..))
import Unison.Util.Text qualified as UText
import Unison.Wasm.ABI qualified as ABI
import Unison.Wasm.Emit (WatInstr (..))

-- | Error type for literal compilation
data LiteralError
  = UnsupportedLiteral String
  deriving (Eq, Show)

-- | Compile a literal to WASM instructions
compileLit :: Lit Reference -> Either LiteralError [WatInstr]
compileLit (N n) = pure [I64Const n]
compileLit (I n) = pure [I64Const (fromIntegral n)]
compileLit (F f) = pure [F64Const f, I64ReinterpretF64] -- Store as i64
compileLit (C c) = pure [I64Const (fromIntegral (fromEnum c))] -- Unicode codepoint as i64
compileLit (T utext) = pure $ compileTextLit utext
compileLit (LM _) = Left $ UnsupportedLiteral "Term links not yet supported"
compileLit (LY _) = Left $ UnsupportedLiteral "Type links not yet supported"

-- | Compile a Text literal to WASM instructions.
--
-- Strategy: Allocate heap space and store UTF-8 bytes inline.
-- Uses __text_temp local for the pointer.
compileTextLit :: UText.Text -> [WatInstr]
compileTextLit utext =
  let text = UText.toText utext
      bytes = BS.unpack (Text.Encoding.encodeUtf8 text)
      byteLen = fromIntegral (length bytes) :: Word32
   in [ Comment $ "Text literal: " ++ show (take 20 (Text.unpack text)) ++ if Text.length text > 20 then "..." else "",
        -- Allocate text object
        I32Const byteLen,
        Call "__alloc_text",
        LocalSet "__text_temp"
      ]
        ++ concatMap (storeByteAt (fromIntegral ABI.textDataOffset)) (zip [0 ..] bytes)
        ++
        -- Return pointer as i64
        [ LocalGet "__text_temp",
          I64ExtendI32U
        ]
  where
    storeByteAt :: Word32 -> (Int, Word8) -> [WatInstr]
    storeByteAt baseOffset (idx, byte) =
      [ LocalGet "__text_temp",
        I32Const (fromIntegral byte),
        I32Store8 (baseOffset + fromIntegral idx)
      ]

