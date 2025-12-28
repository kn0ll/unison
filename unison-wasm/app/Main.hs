-- | Phase 1 Proof-of-Concept CLI for WASM emission.
--
-- This executable emits hardcoded WAT for testing the emission pipeline.
--
-- Usage:
--   unison-wasm-poc emit-increment    -- Emit the increment function as WAT
module Main where

import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import Unison.Wasm.Emit (emitModule, incrementModule)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["emit-increment"] -> do
      putStr (emitModule incrementModule)
    [] -> usage
    _ -> do
      hPutStrLn stderr $ "Unknown command: " ++ unwords args
      usage
      exitFailure

usage :: IO ()
usage = do
  hPutStrLn stderr "Usage: unison-wasm-poc <command>"
  hPutStrLn stderr ""
  hPutStrLn stderr "Commands:"
  hPutStrLn stderr "  emit-increment    Emit the increment function as WAT"
