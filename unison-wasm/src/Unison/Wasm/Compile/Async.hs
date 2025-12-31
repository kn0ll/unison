-- | Async state machine transformation for yield/resume.
--
-- This module transforms function bodies that contain yield points (async FFI calls)
-- into state machines that can be suspended and resumed.
--
-- The transformation takes instruction streams with YieldPointStart/YieldPointEnd
-- markers and produces a proper state machine with:
-- 1. A resume dispatcher at function entry
-- 2. br_table to jump to the correct resume point
-- 3. Proper control flow using nested blocks
module Unison.Wasm.Compile.Async
  ( transformToStateMachine,
    hasYieldPoints,
    countYieldPoints,
  )
where

import Unison.Wasm.Emit (WatInstr (..), WatValType (..))
import qualified Unison.Wasm.ABI as ABI
import Data.List (foldl')

-- | Check if an instruction list contains any yield points
hasYieldPoints :: [WatInstr] -> Bool
hasYieldPoints = any isYieldMarker
  where
    isYieldMarker (YieldPointStart _) = True
    isYieldMarker (YieldPointEnd _) = True
    isYieldMarker (Block _ instrs) = hasYieldPoints instrs
    isYieldMarker (BlockResult _ _ instrs) = hasYieldPoints instrs
    isYieldMarker (Loop _ instrs) = hasYieldPoints instrs
    isYieldMarker (If _ thenBr elseBr) = hasYieldPoints thenBr || hasYieldPoints elseBr
    isYieldMarker (IfVoid thenBr elseBr) = hasYieldPoints thenBr || hasYieldPoints elseBr
    isYieldMarker _ = False

-- | Count the number of yield points in an instruction list
countYieldPoints :: [WatInstr] -> Int
countYieldPoints = foldl' countInstr 0
  where
    countInstr n (YieldPointStart _) = n + 1
    countInstr n (Block _ instrs) = n + countYieldPoints instrs
    countInstr n (BlockResult _ _ instrs) = n + countYieldPoints instrs
    countInstr n (Loop _ instrs) = n + countYieldPoints instrs
    countInstr n (If _ thenBr elseBr) = n + countYieldPoints thenBr + countYieldPoints elseBr
    countInstr n (IfVoid thenBr elseBr) = n + countYieldPoints thenBr + countYieldPoints elseBr
    countInstr n _ = n

-- | A segment of code between yield points
data Segment = Segment
  { segmentId :: Int,           -- State number for this segment
    segmentCode :: [WatInstr],  -- Code in this segment (without yield markers)
    segmentYieldId :: Maybe Int -- If this segment ends with a yield, its ID
  }
  deriving (Show)

-- | Transform a function body with yield points into a state machine.
--
-- This transformation:
-- 1. Splits the instruction stream at yield points into segments
-- 2. Wraps each segment in the state machine loop
-- 3. Adds a resume dispatcher at the entry point
-- 4. Removes yield point markers
--
-- The resulting code structure:
-- @
-- (block $exit
--   (loop $state_loop
--     (block $state_N
--       ...
--       (block $state_1
--         (block $state_0
--           (local.get $__state)
--           (br_table $state_0 $state_1 ... $state_N $exit)
--         )
--         ;; STATE 0 code
--         (i32.const 1)
--         (local.set $__state)
--         (br $state_loop)
--       )
--       ;; STATE 1 code
--       ...
--     )
--     ;; STATE N code (final state)
--     (br $exit)
--   )
-- )
-- @
transformToStateMachine ::
  [(String, WatValType)] ->  -- All locals (for restoration)
  [WatInstr] ->              -- Original function body
  [WatInstr]                 -- Transformed function body
transformToStateMachine locals body =
  if not (hasYieldPoints body)
    then body  -- No yield points, return unchanged
    else
      let segments = splitIntoSegments body
          numStates = length segments
          stateLabels = ["__state_" ++ show i | i <- [0 .. numStates - 1]]
      in resumeDispatcher locals ++ stateMachineBody segments stateLabels

-- | Generate the resume dispatcher at function entry.
-- This checks if we're resuming and sets up the state accordingly.
resumeDispatcher :: [(String, WatValType)] -> [WatInstr]
resumeDispatcher locals =
  [ Comment "=== Resume Dispatcher ===",
    GlobalGet "__async_resuming",
    IfVoid
      ( [ Comment "Resuming from yield - restore state",
          -- Clear the resuming flag
          I32Const 0,
          GlobalSet "__async_resuming",
          -- Restore K pointer
          GlobalGet "async_cont_ptr",
          I32Load (fromIntegral ABI.asyncContKPtrOffset),
          GlobalSet "k_ptr",
          -- Get locals pointer
          GlobalGet "async_cont_ptr",
          I32Load (fromIntegral ABI.asyncContLocalsPtrOffset),
          LocalSet "__async_locals_ptr"
        ]
        -- Restore each local from the saved array
        ++ restoreLocals locals
        ++ [ -- Set __ffi_result to the resume value
             GlobalGet "__async_resume_value",
             LocalSet "__ffi_result",
             -- Get the resume label (state to jump to)
             GlobalGet "async_cont_ptr",
             I32Load (fromIntegral ABI.asyncContResumeLabelOffset),
             LocalSet "__state"
           ]
      )
      [ -- Normal entry: start at state 0
        I32Const 0,
        LocalSet "__state"
      ]
  ]

-- | Generate instructions to restore all locals from the saved array
restoreLocals :: [(String, WatValType)] -> [WatInstr]
restoreLocals locals =
  concatMap restoreLocal (zip [0..] locals)
  where
    restoreLocal (idx, (name, _)) =
      [ LocalGet "__async_locals_ptr",
        I64Load (fromIntegral (idx * 8 :: Int)),
        LocalSet name
      ]

-- | Split instruction stream into segments at yield points.
-- Each segment corresponds to a state in the state machine.
splitIntoSegments :: [WatInstr] -> [Segment]
splitIntoSegments instrs =
  let (segments, finalCode) = go 0 [] instrs
      -- Add final segment if there's remaining code
      allSegments = if null finalCode
                    then segments
                    else segments ++ [Segment (length segments) finalCode Nothing]
  in allSegments
  where
    -- go stateId currentSegmentCode remainingInstrs
    go :: Int -> [WatInstr] -> [WatInstr] -> ([Segment], [WatInstr])
    go _stateId acc [] = ([], reverse acc)
    go stateId acc (YieldPointStart yieldId : rest) =
      -- Start of yield point: include the FFI call in current segment
      let (yieldCode, afterYield) = collectUntilYieldEnd yieldId rest
          -- Current segment ends here (before FFI call)
          segment = Segment stateId (reverse acc ++ yieldCode) (Just yieldId)
          -- Recursively process rest, starting new segment
          (moreSegments, finalCode) = go (stateId + 1) [] afterYield
      in (segment : moreSegments, finalCode)
    go stateId acc (YieldPointEnd _ : rest) =
      -- Should not happen if markers are properly paired
      go stateId acc rest
    go stateId acc (instr : rest) =
      -- Regular instruction: add to current segment
      -- Need to recursively process nested control flow
      let processedInstr = processNestedYields instr
      in go stateId (processedInstr : acc) rest

    -- Collect instructions until we hit YieldPointEnd with matching ID
    collectUntilYieldEnd :: Int -> [WatInstr] -> ([WatInstr], [WatInstr])
    collectUntilYieldEnd targetId instrs' = go' [] instrs'
      where
        go' acc [] = (reverse acc, [])
        go' acc (YieldPointEnd yId : rest)
          | yId == targetId = (reverse acc, rest)
          | otherwise = go' (YieldPointEnd yId : acc) rest
        go' acc (instr : rest) = go' (instr : acc) rest

    -- Process yield points in nested control structures
    processNestedYields :: WatInstr -> WatInstr
    processNestedYields (Block lbl inner) = Block lbl (removeYieldMarkers inner)
    processNestedYields (BlockResult lbl ty inner) = BlockResult lbl ty (removeYieldMarkers inner)
    processNestedYields (Loop lbl inner) = Loop lbl (removeYieldMarkers inner)
    processNestedYields (If ty thenBr elseBr) =
      If ty (removeYieldMarkers thenBr) (removeYieldMarkers elseBr)
    processNestedYields (IfVoid thenBr elseBr) =
      IfVoid (removeYieldMarkers thenBr) (removeYieldMarkers elseBr)
    processNestedYields other = other

-- | Remove yield point markers from an instruction list (for nested structures)
removeYieldMarkers :: [WatInstr] -> [WatInstr]
removeYieldMarkers = concatMap process
  where
    process (YieldPointStart _) = []
    process (YieldPointEnd _) = []
    process (Block lbl inner) = [Block lbl (removeYieldMarkers inner)]
    process (BlockResult lbl ty inner) = [BlockResult lbl ty (removeYieldMarkers inner)]
    process (Loop lbl inner) = [Loop lbl (removeYieldMarkers inner)]
    process (If ty thenBr elseBr) =
      [If ty (removeYieldMarkers thenBr) (removeYieldMarkers elseBr)]
    process (IfVoid thenBr elseBr) =
      [IfVoid (removeYieldMarkers thenBr) (removeYieldMarkers elseBr)]
    process other = [other]

-- | Generate the state machine body with proper br_table dispatch.
stateMachineBody :: [Segment] -> [String] -> [WatInstr]
stateMachineBody segments stateLabels =
  let exitLabel = "__exit"
      loopLabel = "__state_loop"
  in
  [ Comment "=== State Machine Body ===",
    Block exitLabel
      [ Loop loopLabel
          ( nestedBlocks stateLabels
              ++ [ -- br_table dispatch
                   LocalGet "__state",
                   BrTable stateLabels exitLabel
                 ]
              ++ stateCode segments loopLabel exitLabel
          )
      ]
  ]

-- | Generate nested block structure for br_table targets.
-- br_table jumps to the END of a block, so we need nested blocks
-- where the innermost is state_0.
nestedBlocks :: [String] -> [WatInstr]
nestedBlocks [] = []
nestedBlocks labels =
  -- Create nested blocks: innermost = first label
  foldr wrapBlock [] labels
  where
    wrapBlock lbl inner = [Block lbl inner]

-- | Generate the code for each state.
-- States are arranged after their corresponding blocks.
stateCode :: [Segment] -> String -> String -> [WatInstr]
stateCode [] _ _ = []
stateCode segments loopLabel exitLabel =
  -- Generate code for each segment in order
  -- The br_table + nested blocks structure means:
  -- - br to $state_0 exits innermost block (lands at state 0 code)
  -- - br to $state_1 exits next block (lands at state 1 code)
  -- etc.
  concatMap (genStateCode (length segments)) (zip [0..] segments)
  where
    genStateCode :: Int -> (Int, Segment) -> [WatInstr]
    genStateCode numStates (idx, seg) =
      [ Comment $ "=== STATE " ++ show idx ++ " ===" ]
      ++ segmentCode seg
      ++ transitionCode idx numStates (segmentYieldId seg)

    -- Generate transition to next state or exit
    transitionCode :: Int -> Int -> Maybe Int -> [WatInstr]
    transitionCode idx numStates maybeYield =
      if idx >= numStates - 1
        then
          -- Final state: exit the loop
          [ Br exitLabel ]
        else case maybeYield of
          Just _ ->
            -- This state ends with a yield point
            -- If we get here (didn't yield), continue to next state
            [ I32Const (fromIntegral (idx + 1)),
              LocalSet "__state",
              Br loopLabel
            ]
          Nothing ->
            -- No yield in this state, just continue
            [ I32Const (fromIntegral (idx + 1)),
              LocalSet "__state",
              Br loopLabel
            ]
