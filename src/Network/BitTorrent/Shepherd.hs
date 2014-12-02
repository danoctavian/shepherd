{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TupleSections #-}

-- Bittorrent tracker; extensions: compact

module Network.BitTorrent.Shepherd (
  runTracker
  ) where
import Web.Scotty
import Network.Socket
import Control.Monad
import Control.Monad.Trans
import Network.Wai
import qualified Data.Text.Lazy as T
import qualified Data.List  as DL
import Control.Applicative as CL
import Data.Word
import Data.BEncode
import qualified Data.Map as Map
import Network.HTTP.Types.Status
import Data.ByteString.Char8 as DBC
import Prelude as P
import Data.Maybe
import Data.Time.Clock
import Data.ByteString.Lazy as DBL
import Data.ByteString.Lazy.Char8 as DBLC
import Data.ByteString as DB
import Data.Binary.Put
import Network.BitTorrent.Shepherd.Utils
import Network.BitTorrent.Shepherd.TrackerDB
import Network.BitTorrent.Shepherd.HashTableTrackerDB

import Control.Concurrent.STM.TVar
import Control.Concurrent.STM
import qualified Data.Map.Strict as SMap
import qualified Data.Vector as DV
import Data.Hashable

data Announce = Announce { info_hash :: InfoHash
                         , peer_id :: PeerID
                         , port :: Word16
                         , uploaded :: Int
                         , downloaded :: Int
                         , left :: Int
                         , event :: Maybe Event
                         , numwant :: Maybe Int
                         , ip :: Maybe String
                         , compact :: Maybe Compact
                       } deriving (Show)
type Scrape = [InfoHash]


data AnnounceResponse = AnnounceResponse { interval :: Int, leechers :: Int, seeders :: Int, swarmPeers :: [PeerAddr]}
  deriving (Show)
data ScrapeResponse = ScrapeResponse {scDownloaded :: Int, scLeechers :: Int, scSeeders :: Int}
  deriving (Show)

data PeerState = Seeder | Leecher deriving (Eq, Show)
data Peer = Peer {peerAddr :: PeerAddr, peerState :: PeerState, lastAction :: UTCTime}
  deriving (Show)
data PeerAddr = PeerAddr {peerId :: PeerID, peerRemoteHost :: SockAddr, peerPort :: Word16}
  deriving (Show)

type InfoHash = String
type PeerID = String

data Event = Started | Completed | Stopped
  deriving (Eq, Read, Show)

data Compact = Compact Bool
  deriving (Eq, Read, Show)

-- constants
maxAllowedPeers = 55
defaultAllowedPeers = 50
infoHashLen = 20
peerIdLen = 20
-- TODO: make this a configuration parameter not a constant
defaultAnnounceInterval = 10 -- in seconds 
                
-- TODO: add proper logging and remove all putStrLn
runTracker port = do
  P.putStrLn "running tracker now"
  db <- htDB
  scotty port $ do

    get "/announce" $ do
      liftIO $ P.putStrLn "got announce"
      ps <- params
      liftIO $ P.putStrLn $ "announce params are " ++ (show ps) 
      announceRes <- readAnnounce <$> params
      liftIO $ P.putStrLn $ "finished reading announce"
      case announceRes of 
        Left errCode -> do
          liftIO $ P.putStrLn $ "failed with errcode " ++ (show errCode)
          status $ errorCodeToStatus errCode
        Right announce -> do
          remoteH <- fmap remoteHost request
          liftIO $ P.putStrLn $ "handling announce from " ++ (show remoteH)
          r <- liftIO $ handleAnnounce db announce remoteH
          liftIO $ P.putStrLn $ "response to ann is " ++ (show $ DBLC.pack r)
          rawText $ DBLC.pack r
    get "/scrape" $ do 
      ps <- readScrape <$> params
      liftIO $ P.putStrLn $ "scrape params are " ++ (show ps) 
      r <- liftIO $ handleScrape db ps
      liftIO $ P.putStrLn $ "response to scrape is " ++ r
      rawText $ DBLC.pack r


rawText bs = do
  setHeader "Content-Type" "text/plain"
  raw bs


{- ANNOUNCE handling -}

readAnnounce params
  = Announce     <$> getParam "info_hash" MISSING_INFO_HASH
                 <*> getParam "peer_id" MISSING_PEER_ID
                 <*> getParam "port" MISSING_PORT
                 <*> getParam "uploaded" GENERIC_ERROR
                 <*> getParam "downloaded" GENERIC_ERROR
                 <*> getParam "left" GENERIC_ERROR
                 <*> (getOptParam "event")
                 <*> (getOptParam "numwanst")
                 <*> (getOptParam "ip")
                 <*> (getOptParam "compact")
    where  
      getParam pName errCode = (maybeToEither errCode $ DL.lookup pName params)
                        >>= (textToErr parseParam)
      getOptParam pName = case DL.lookup pName params of
                            Just ptext -> fmap Just $ (textToErr parseParam) ptext
                            Nothing -> return Nothing
      textToErr c x = case c x of
                       Left errTxt -> Left GENERIC_ERROR
                       Right v -> Right v 

handleAnnounce db ann remoteHost = do
  maybePeer <- getPeer db (info_hash ann) (peer_id ann)
  now <- getCurrentTime
  let peerUpdate = announceUpdate ann remoteHost maybePeer now
  case peerUpdate of 
      Add infoH p -> putPeer db infoH (peer_id ann) p
      Delete infoH pid -> deletePeer db infoH pid            
  -- fmap (P.filter ((/= (peer_id ann)) . peerId . peerAddr)) $ 
  allPeers <- getPeers db (info_hash ann)
              (maybe defaultAllowedPeers id (numwant ann))
  P.putStrLn $ show $ makeAnnounceResponse allPeers
  return .  (\b -> bShow b "") . bencodeAnnResponse ann . makeAnnounceResponse $ allPeers

-- pure logic for what happens when a peer comes in
data PeerAction = Add InfoHash Peer | Delete InfoHash PeerID
announceUpdate ann ip oldPeer now
  = case oldPeer of
    Just old -> case (event ann) of
      Just Stopped -> Delete iHash (peerId $ peerAddr old)
      other -> Add iHash newPeer -- updating it's state
    Nothing -> Add iHash newPeer
    where
      iHash = info_hash ann
      newState = (if' (left ann > 0) Leecher Seeder)
      newPeer = Peer (PeerAddr {peerId = peer_id ann, peerRemoteHost = ip, peerPort = port ann})
                    newState now

validateAnnounce ann
  | (P.length $ info_hash ann) /= infoHashLen = Left INVALID_INFO_HASH
  | (P.length $ peer_id ann) /= peerIdLen = Left INVALID_PEER_ID
  | (not . isNothing . numwant $ ann) &&
      ((fromJust $ numwant ann) > maxAllowedPeers) = Left INVALID_NUMWANT
  | otherwise = Right ann --announce is valid

makeAnnounceResponse peers
  = AnnounceResponse { leechers = countPeers Leecher peers
                     , seeders = countPeers Seeder peers
                     , swarmPeers = P.map peerAddr peers
                     , interval = defaultAnnounceInterval }

              

{- SCRAPE handling -}
readScrape = P.map (T.unpack . snd) . P.filter ((== "info_hash") . fst)

-- TODO: incorrect impl. values are sometimes correct
-- need to keep track of downloads and an efficient way of counting seeders/leechers
handleScrape db infoHashes =
   (\b -> bShow b "") . bencodeScrapeResponse <$>
    (forM infoHashes $ \infoHash -> do
      peers <- (infoHash,) . makeScrapeResponse <$> getPeers db infoHash defaultAllowedPeers
      P.putStrLn $ show peers 
      return peers
    )

makeScrapeResponse peers
  = ScrapeResponse { scSeeders = countPeers Seeder peers
                   , scLeechers = countPeers Leecher peers
                   , scDownloaded = 0 } 

{-

data store operations

add
del
get
getall
-}



{-
  peer store: fixed size hash table with maps of swarms in each buckets
  for no single contention point; threads compete for access to the tvars
  containing the swarm buckets
-}

torrentBucketCount = 2 ^ 10
data PeerStore = PeerStore (DV.Vector (TVar (SMap.Map InfoHash (SMap.Map PeerID Peer))))

initPeerStore = do
  buckets <- replicateM torrentBucketCount $ newTVarIO SMap.empty
  return $ PeerStore $ DV.fromList buckets

getBucket table infoHash = table DV.! ((hash infoHash) `mod` (DV.length table))

addP infoHash peerId peer  (PeerStore table) = do
  modifyTVar (getBucket table infoHash)
    (\ts -> (\swarm -> SMap.insert infoHash swarm ts)
      $ SMap.insert peerId peer $ fromJust
      $ mplus (SMap.lookup infoHash ts) (Just SMap.empty))

delP infoHash peerId (PeerStore table) = do
  modifyTVar (getBucket table infoHash)
    (\ts -> case SMap.lookup (infoHash) ts of
              Nothing -> ts
              (Just swarm) -> SMap.insert infoHash (SMap.delete peerId swarm) ts)

getP infoHash peerId (PeerStore table) = do
  fmap (\ts -> SMap.lookup infoHash ts >>= SMap.lookup peerId)
             $ readTVar (getBucket table infoHash)

getPs infoHash numWant (PeerStore table) = do
  ts <- readTVar (getBucket table infoHash)
  return $ case SMap.lookup infoHash ts of
    Just swarm -> P.take numWant $ SMap.toList swarm
    Nothing -> []

{- BENCODE functions -}


bencodeAnnResponse ann r
  = BDict $ Map.fromList
            [("interval", bint $ interval r),
             ("complete", bint $ seeders r),
             ("incomplete", bint $ leechers r),
             ("peers", bencodePeers (compact ann) $ swarmPeers r)]       

bencodeScrapeResponse scrapeResponses
  = BDict $ Map.fromList
    [("files", BDict $ Map.fromList $ P.map
      (\(ih, r) -> (ih, BDict $ Map.fromList [("complete", bint $ scSeeders r)
                                        , ("incomplete", bint $ scLeechers r)
                                        , ("downloaded", bint $ scDownloaded r)]))
      scrapeResponses)]

bencodePeers compact peers
   = if' (maybe False (\(Compact t) -> t) compact)
     (BString . DBL.concat . catMaybes . P.map encodePeer $ peers)
     (BList $ P.map (\p -> BDict $ Map.fromList
        [("peer id", BString . DBLC.pack $ peerId p),
         ("ip", BString . DBLC.pack $ stringIP $ show $ peerRemoteHost $ p),
         ("port", BInt $ fromIntegral $ peerPort p)]) peers)

{- the 6 bytes encoding of a peer
  this solves only IPv4 addresses
  address encoding should be big endian but for some reason 127.0.0.1 is
  represented in little endian (1.0.0.127)
-}
encodePeer peer = case (peerRemoteHost peer) of
  SockAddrInet port hostAddr -> Just $ runPut (putWord32le hostAddr >> putWord16be (peerPort peer))
  other -> Nothing -- we don't encode IPv6 or anything else

bint = BInt . fromIntegral             
countPeers s peers = P.length . P.filter ((== s) . peerState) $ peers



{- ERROR responses -}

-- Error responses
data ErrorCode = 
    INVALID_REQUEST_TYPE
  | MISSING_INFO_HASH
  | MISSING_PEER_ID
  | MISSING_PORT
  | INVALID_INFO_HASH
  | INVALID_PEER_ID
  | INVALID_NUMWANT
  | GENERIC_ERROR
    deriving (Show)

errorCodeToStatus code
  = case code of 
      INVALID_REQUEST_TYPE ->  Status 100 "Invalid Request type"
      MISSING_INFO_HASH  ->  Status 101  "Missing info_hash field"
      MISSING_PEER_ID -> Status 102  "Missing peer_id field"
      MISSING_PORT -> Status 103 "Missing port field"
      INVALID_INFO_HASH -> Status 150 $ DBC.pack $ "info_hash is not " ++ (show infoHashLen) ++ " bytes"
      INVALID_PEER_ID -> Status 151 $ DBC.pack $ "peer_id is not " ++ (show peerIdLen) ++ " bytes"
      INVALID_NUMWANT -> Status 152 $ DBC.pack $ "peers more than " ++ (show maxAllowedPeers) ++ " is not allowed"
      GENERIC_ERROR -> Status 900 $ DBC.pack $ "Error in request"


instance Parsable Word16 where parseParam = readEither
instance Parsable Event where
  parseParam "stopped" = Right Stopped
  parseParam "started" = Right Started
  parseParam "completed" = Right Completed
  parseParam _ = Left "failed parse event"

instance Parsable Compact where
  parseParam "1" = Right $ Compact True
  parseParam "0" = Right $ Compact False
  parseParam _ = Left "failed parse event"

stringIP = P.takeWhile (/= ':') . show 

{-
HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 105\r\n\r\nd8:completei1e10:downloadedi2e10:incompletei1e8:intervali1927e12:min intervali963e5:peers12:\DEL\NUL\NUL\SOH\SUB\225\DEL\NUL\NUL\SOH\SUB\235e
-}
