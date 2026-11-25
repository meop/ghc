module Main (main) where

import Control.Exception (evaluate)
import Data.IORef (newIORef, readIORef)
import Data.List (foldl')
import System.Mem (performMajorGC)

-- A function with more than 64 pointer arguments has a "large" argument
-- bitmap (ARG_GEN_BIG).  With tables-next-to-code the info table does not
-- point at that bitmap: it holds an 8-byte offset (bitmap_offset) from the
-- info table to a bitmap in another section, and the RTS must read it
-- correctly.  The COFF AArch64 toolchain can only relocate the low 32 bits
-- of such a field (there is no 64-bit PC-relative relocation), so an RTS that
-- reads all 8 bytes finds garbage in the upper half and crashes in the
-- garbage collector.  See Note [x86-64-relative] in
-- rts/include/rts/storage/InfoTables.h.
--
-- 1. A partial application (PAP) of such a function is kept alive across
--    major collections.  The collector scavenges the PAP's payload with the
--    function's large bitmap (C code, GET_FUN_LARGE_BITMAP).
-- 2. Entering the function with a nearly full nursery (-A32k) makes its heap
--    check fail, so stg_gc_fun computes the size of the arguments on the
--    stack from the same bitmap (Cmm code, StgFunInfoExtraRev_bitmap_offset).
--
-- k stays lazy in every argument and is OPAQUE, so the optimiser can neither
-- unbox or drop arguments (which would shrink the bitmap) nor inline it.
{-# OPAQUE k #-}
k :: Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int ->
     Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int ->
     Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int ->
     Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int ->
     Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int ->
     Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int ->
     Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> [Int]
k a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 a13
  a14 a15 a16 a17 a18 a19 a20 a21 a22 a23 a24 a25 a26
  a27 a28 a29 a30 a31 a32 a33 a34 a35 a36 a37 a38 a39
  a40 a41 a42 a43 a44 a45 a46 a47 a48 a49 a50 a51 a52
  a53 a54 a55 a56 a57 a58 a59 a60 a61 a62 a63 a64 a65
  a66 a67 a68 a69 a70 =
  [ a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12,
    a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24,
    a25, a26, a27, a28, a29, a30, a31, a32, a33, a34, a35, a36,
    a37, a38, a39, a40, a41, a42, a43, a44, a45, a46, a47, a48,
    a49, a50, a51, a52, a53, a54, a55, a56, a57, a58, a59, a60,
    a61, a62, a63, a64, a65, a66, a67, a68, a69, a70 ]

main :: IO ()
main = do
  -- Call k through an IORef so that the partial applications are built at
  -- run time by stg_ap_*: GHC cannot then eta-expand them into new functions.
  ref <- newIORef k
  f <- readIORef ref
  let p3  = f 1 2 3
      p40 = f 1 2 3 4 5 6 7 8 9 10 11 12 13 14
          15 16 17 18 19 20 21 22 23 24 25 26 27 28
          29 30 31 32 33 34 35 36 37 38 39 40
  _ <- evaluate p3
  _ <- evaluate p40
  performMajorGC
  performMajorGC
  print (sum (p3 4 5 6 7 8 9 10 11 12 13 14 15 16 17
      18 19 20 21 22 23 24 25 26 27 28 29 30 31
      32 33 34 35 36 37 38 39 40 41 42 43 44 45
      46 47 48 49 50 51 52 53 54 55 56 57 58 59
      60 61 62 63 64 65 66 67 68 69 70))
  print (sum (p40 41 42 43 44 45 46 47 48 49 50 51 52 53 54
      55 56 57 58 59 60 61 62 63 64 65 66 67 68
      69 70))
  print (foldl' (\acc i -> acc + sum (k i
    2 3 4 5 6 7 8 9 10 11 12 13 14 15
    16 17 18 19 20 21 22 23 24 25 26 27 28 29
    30 31 32 33 34 35 36 37 38 39 40 41 42 43
    44 45 46 47 48 49 50 51 52 53 54 55 56 57
    58 59 60 61 62 63 64 65 66 67 68 69 70))
                0 [1 .. 2000 :: Int])
