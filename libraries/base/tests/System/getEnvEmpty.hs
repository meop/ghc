import Control.Monad (when)
import System.Environment (getEnv, lookupEnv)
import qualified System.Environment.Blank as Blank
import System.IO.Error (isDoesNotExistError, tryIOError)

-- 'setEnv' with an empty value unsets the variable (by design), so this test
-- uses "System.Environment.Blank", which really sets it to the empty string.

-- Report 'getEnv' as a value, or as the kind of error it threw.
getEnvResult :: String -> IO String
getEnvResult name = do
  r <- tryIOError (getEnv name)
  return $ case r of
    Right v -> "Right " ++ show v
    Left e | isDoesNotExistError e -> "Left does-not-exist"
           | otherwise             -> "Left other: " ++ show e

report :: String -> IO ()
report name = do
  lookupEnv name >>= print
  getEnvResult name >>= putStrLn
  Blank.getEnv name >>= print

main :: IO ()
main = do
  let var     = "GHC_TEST_EMPTY_ENV_VAR"
      missing = "GHC_TEST_MISSING_ENV_VAR"
  Blank.unsetEnv var
  Blank.unsetEnv missing

  putStrLn "-- not set"
  report var

  putStrLn "-- set to the empty string"
  Blank.setEnv var "" True
  report var

  -- Looking up a variable that is not set must not leave a state that makes
  -- a later lookup of the empty variable report it as missing.
  putStrLn "-- missing, then empty again"
  report missing
  report var

  putStrLn "-- set to a value"
  Blank.setEnv var "value" True
  report var

  putStrLn "-- set to a value longer than the first buffer"
  let long = replicate 1000 'x'
  Blank.setEnv var long True
  r <- lookupEnv var
  when (r /= Just long) $ putStrLn "long value: WRONG"
  getEnv var >>= \v -> putStrLn ("long value length " ++ show (length v))

  putStrLn "-- unset again"
  Blank.unsetEnv var
  report var
