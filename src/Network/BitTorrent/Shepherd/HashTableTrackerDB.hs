module Network.BitTorrent.Shepherd.HashTableTrackerDB (
   htDB
  ) where

import Control.Monad
import Control.Monad.Trans
import Control.Applicative as CL
import Prelude as P
import Data.HashTable.IO as DHI
import Control.Monad.Trans.Maybe
import Control.Concurrent.Lock as Lock
import Network.BitTorrent.Shepherd.TrackerDB
import Network.BitTorrent.Shepherd.Utils


htDB :: (MonadIO m) => m (TrackerDB k1 k2 a)
htDB = do
  -- TODO: check if BasicHashTable is the right choice
  fileHT <- liftIO $ (DHI.new :: IO (BasicHashTable k1 (BasicHashTable k2 a)))
  -- slow solution but it should work for now - use a lock over the whole data structure
  lock <- liftIO $ Lock.new
  let mutex comp = (comp (\c -> with lock $ c fileHT) )
  return $ TrackerDB  (mutex (.**) putP)
                     (mutex (.*) deleteP) (mutex (.*) getP) (mutex (.*) getPs)

putP infoHash peerId peer fileHT = do
  maybeSwarm <- DHI.lookup fileHT infoHash
  case maybeSwarm of 
    Just swarm -> DHI.insert swarm peerId peer
    Nothing -> do
      swarmTable <- liftIO $ DHI.fromList [(peerId, peer)]

      DHI.insert fileHT infoHash swarmTable

deleteP infoHash peerId fileHT = do
  maybeSwarm <- DHI.lookup fileHT infoHash
  case maybeSwarm of
    Just swarm -> DHI.delete swarm peerId
    Nothing -> return () -- do nothing

getP infoHash peerId fileHT
  = runMaybeT $
     (liftIO $ DHI.lookup fileHT infoHash) >>= liftMaybe
     >>= (\f ->  liftIO $  DHI.lookup f peerId) >>= liftMaybe

getPs infoHash numWant fileHT = do
  maybeSwarm <- (liftIO $ DHI.lookup fileHT infoHash)
  case maybeSwarm of 
    Just swarm -> (P.take numWant . P.map snd) <$> (DHI.toList swarm)
    Nothing -> return []





