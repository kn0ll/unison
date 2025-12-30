{-# OPTIONS_GHC -Wno-unused-imports #-}
{-# OPTIONS_GHC -fno-warn-incomplete-patterns #-}

module Main where

import EasyTest
import System.Environment (getArgs)
import System.IO
import System.IO.CodePage (withCP65001)
import Unison.Test.Wasm.ABI qualified as ABI
import Unison.Test.Wasm.Abilities qualified as Abilities
import Unison.Test.Wasm.Codebase qualified as Codebase
import Unison.Test.Wasm.Compile qualified as Compile
import Unison.Test.Wasm.Emit qualified as Emit
import Unison.Test.Wasm.Fixtures qualified as Fixtures
import Unison.Test.Wasm.Integration qualified as Integration
import Unison.Test.Wasm.TypeScript qualified as TypeScript

test :: Test ()
test =
  tests
    [ ABI.test,
      Abilities.test,
      Codebase.test,
      Compile.test,
      Emit.test,
      Fixtures.test,
      Integration.test,
      TypeScript.test
    ]

main :: IO ()
main = withCP65001 do
  args <- getArgs
  mapM_ (`hSetEncoding` utf8) [stdout, stdin, stderr]
  case args of
    [] -> runOnly "" test
    [prefix] -> runOnly prefix test
    [seed, prefix] -> rerunOnly (read seed) prefix test
