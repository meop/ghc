{-# LANGUAGE GHCForeignImportPrim #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnliftedFFITypes #-}

import GHC.Exts
import GHC.Int

foreign import prim "bar" bar :: Int64# -> Int64#

main :: IO ()
main = print (I64# (bar (intToInt64# 5#)))
