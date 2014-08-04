{-# LANGUAGE RankNTypes #-}
module Network.BitTorrent.Shepherd.TrackerDB where

import Data.Hashable

data TrackerDB k1 k2 a = TrackerDB {
    putPeer :: (Hashable k1, Eq k1, Hashable k2, Eq k2) => k1 -> k2 -> a -> IO () -- update if already exists
  , deletePeer :: (Hashable k1, Eq k1, Hashable k2, Eq k2) =>  k1 -> k2 -> IO ()
  , getPeer :: (Hashable k1, Eq k1, Hashable k2, Eq k2) => k1 -> k2 -> IO (Maybe a)
  , getPeers :: (Hashable k1, Eq k1, Hashable k2, Eq k2) => k1 -> Int -> IO [a] -- fetches all peers
}
