module Main where

import Network.BitTorrent.Shepherd

main = do
  putStrLn "running server"
  runTracker $ Config {listenPort = 6666, events = Nothing}
