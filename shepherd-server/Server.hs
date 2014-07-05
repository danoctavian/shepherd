module Main where

import Network.BitTorrent.Shepherd

main = do
  putStrLn "running server"
  runTracker
