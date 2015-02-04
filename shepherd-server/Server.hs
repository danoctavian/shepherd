module Main where

import System.Environment
import Data.Word
import Network.BitTorrent.Shepherd
import System.Log.Logger

main = do
  updateGlobalLogger logger  (setLevel DEBUG)
  args <- getArgs 
  let port = (read (head args) :: Word16)
  putStrLn $ "running tracker server on port " ++ (show port)
  runTracker $ Config {listenPort = port, events = Nothing}
