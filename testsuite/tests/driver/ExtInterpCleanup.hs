{-# LANGUAGE TemplateHaskell #-}
module ExtInterpCleanup where

import Language.Haskell.TH

-- The splice makes the external interpreter start.
x :: Int
x = $(litE (integerL 42))
