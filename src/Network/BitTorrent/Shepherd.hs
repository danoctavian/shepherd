{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE NoMonomorphismRestriction #-}

module Network.BitTorrent.Shepherd where
import Web.Scotty
import Network.Wai.Middleware.RequestLogger -- install wai-extra if you don't have this
import Control.Monad
import Control.Monad.Trans
import Network.HTTP.Types (status302)
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
import Control.Concurrent.STM
import Data.HashTable.IO as DHI
import Data.Time.Clock
import Data.ByteString.Lazy.Char8 as DBLC
import qualified Control.Arrow as CA
import Control.Monad.Trans.Maybe


-- Bittorrent tracker; no extensions

data Event = Started | Completed | Stopped
  deriving (Eq, Read)

type InfoHash = String
type PeerID = String

data Announce = Announce { info_hash :: InfoHash
                         , peer_id :: PeerID
                         , port :: Word16
                         , uploaded :: Int
                         , downloaded :: Int
                         , left :: Int
                         , event :: Maybe Event
                         , numwant :: Maybe Int
                         , ip :: Maybe String
                       }


data PeerState = Seeder | Leecher deriving (Eq, Show)
data Peer = Peer {peerAddr :: PeerAddr, peerState :: PeerState, lastAction :: UTCTime}
data PeerAddr = PeerAddr { peerId :: PeerID, peerIP :: String, peerPort :: Word16}


type MonadDB m =  (MonadIO m)

data TrackerDB = TrackerDB {
    putPeer :: InfoHash -> Peer -> IO () -- update if already exists
  , deletePeer :: InfoHash -> PeerID -> IO ()
  , getPeer :: InfoHash -> PeerID -> IO (Maybe Peer)
  , getPeers :: InfoHash -> Int -> IO [Peer] -- fetches all peers
}


putP fileHT infoHash peer = do
  maybeSwarm <- DHI.lookup fileHT infoHash
  case maybeSwarm of 
    Just swarm -> DHI.insert swarm (peerId . peerAddr $ peer) peer
    Nothing -> do
      swarmTable <- liftIO $ (DHI.fromList [(peerId. peerAddr $ peer, peer)]
                      :: IO (BasicHashTable PeerID Peer))
      DHI.insert fileHT infoHash swarmTable

deleteP fileHT infoHash peerId = do
  maybeSwarm <- DHI.lookup fileHT infoHash
  case maybeSwarm of
    Just swarm -> DHI.delete swarm peerId
    Nothing -> return () -- do nothing

getP fileHT infoHash peerId
  = runMaybeT $
     (liftIO $ DHI.lookup fileHT infoHash) >>= liftMaybe
     >>= (\f ->  liftIO $  DHI.lookup f peerId) >>= liftMaybe

getPs fileHT infoHash numWant = do
  maybeSwarm <- (liftIO $ DHI.lookup fileHT infoHash)
  case maybeSwarm of 
    Just swarm -> (P.take numWant . P.map snd) <$> (DHI.toList swarm)
    Nothing -> return []


tvarDB :: (MonadIO m) => m TrackerDB
tvarDB = do
  -- TODO: check if BasicHashTable is the right choice
  fileHT <- liftIO $ (DHI.new :: IO (BasicHashTable InfoHash (BasicHashTable PeerID Peer)))
  tvar <- liftIO $ newTMVarIO fileHT
  return $ TrackerDB (putP fileHT) (deleteP fileHT) (getP fileHT) (getPs fileHT)

-- standard response
data Response = Response { interval :: Int, leechers :: Int, seeders :: Int, swarmPeers :: [PeerAddr]}

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

validateAnnounce ann
  | (P.length $ info_hash ann) /= infoHashLen = Left INVALID_INFO_HASH
  | (P.length $ peer_id ann) /= peerIdLen = Left INVALID_PEER_ID
  | (not . isNothing . numwant $ ann) &&
      ((fromJust $ numwant ann) > maxAllowedPeers) = Left INVALID_NUMWANT
  | otherwise = Right ann --announce is valid

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
    where  
      getParam pName errCode = (maybeToEither errCode $ DL.lookup pName params)
                        >>= (textToErr parseParam)
      getOptParam pName = case DL.lookup pName params of
                            Just ptext -> fmap Just $ (textToErr parseParam) ptext
                            Nothing -> return Nothing
      textToErr c x = case c x of
                       Left errTxt -> Left GENERIC_ERROR
                       Right v -> Right v 


-- event: started, completed, stopped
-- stopped -> delete peer
-- 

data PeerAction = Add InfoHash Peer | Delete InfoHash PeerID
announceUpdate ann ip oldPeer now
  = case oldPeer of
    Just old -> case (event ann) of
      Just Stopped -> Delete iHash (peerId $ peerAddr old)
      Just other -> Add iHash newPeer -- updating it's state
      Nothing -> Add iHash newPeer
    where
      iHash = info_hash ann
      newState = (if' (left ann > 0) Leecher Seeder)
      newPeer = Peer (PeerAddr {peerId = peer_id ann, peerIP = ip, peerPort = port ann})
                    newState now

sumPair (x,y) (a, b) = (x + a, y + b)

handleAnnounce db ann ip = do
  maybePeer <- getPeer db (info_hash ann) (peer_id ann)
  now <- getCurrentTime
  let peerUpdate = announceUpdate ann ip maybePeer now
  case peerUpdate of 
      Add infoH p -> putPeer db infoH p
      Delete infoH pid -> deletePeer db infoH pid
  allPeers <- getPeers db (info_hash ann)
              (if' (isNothing $ numwant ann) defaultAllowedPeers (fromJust $ numwant ann))
  return .  (\b -> bShow b "") . bencodeResponse . makeResponse $ allPeers

makeResponse peers = Response { leechers = count Leecher
                              , seeders = count Seeder
                              , swarmPeers = P.map peerAddr peers
                              , interval = 10
                            }
   where
      count s = P.length . P.filter ((== s) . peerState) $ peers                             

bencodeResponse r
  = BDict $ Map.fromList
            [("interval", bint $ interval r),
             ("complete", bint $ leechers r),
             ("incomplete", bint $ seeders r),
             ("peers", BList $ P.map
               (\p -> BDict $ Map.fromList [("peer_id", BString . DBLC.pack $ peerId p),
                                            ("ip", BString . DBLC.pack $ peerIP p),
                                            ("port", BInt $ fromIntegral $ peerPort p)]) $ swarmPeers r)]
             where
                bint = BInt . fromIntegral

runTracker = do
  P.putStrLn "running tracker"
  scotty 3000 $ do
    -- Add any WAI middleware, they are run top-down.
    --middleware logStdoutDev

    get "/:bar" $ do
      ps <- params
      liftIO $ P.putStrLn $ "params are " ++ (show ps)     
    get "/" $ text "foobar"
    get "/announce" $ do
      ps <- params
      liftIO $ P.putStrLn $ "params are " ++ (show ps) 
      announceRes <- readAnnounce <$> params
      case announceRes of 
        Left errCode -> status $ errorCodeToStatus errCode
        Right announce -> do
          heads <- fmap remoteHost request
          text $ T.pack $ show heads
    get "/scrape" $ do -- just the 
      ps <- params
      liftIO $ P.putStrLn $ "params are " ++ (show ps) 


-- constants
maxAllowedPeers = 55
defaultAllowedPeers = 50
infoHashLen = 20
peerIdLen = 20

instance Parsable Word16 where parseParam = readEither
instance Parsable Event where
  parseParam "stopped" = Right Stopped
  parseParam "started" = Right Started
  parseParam "completed" = Right Completed
  parseParam _ = Left "failed parse event"

-- UTILS
if' c a b = if c then a else b
maybeToEither :: a -> Maybe b -> Either a b
maybeToEither errorValue = maybe (Left errorValue) (\x -> Right x)
liftMaybe :: (MonadPlus m) => Maybe a -> m a
liftMaybe = maybe mzero return


{-

params are [("info_hash","DA\ETXR^m\65533\65533\SOW\65533i ~\65533b\65533\SOH0\65533"),("peer_id","-TR2510-kws2e1c0ye7g"),("port","51413"),("uploaded","0"),("downloaded","0"),("left","0"),("numwant","80"),("key","7e07f200"),("compact","1"),("supportcrypto","1"),("event","started")]
params are [("info_hash","DA\ETXR^m\65533\65533\SOW\65533i ~\65533b\65533\SOH0\65533"),("peer_id","-TR2510-kws2e1c0ye7g"),("port","51413"),("uploaded","0"),("downloaded","0"),("left","0"),("numwant","0"),("key","7e07f200"),("compact","1"),("supportcrypto","1"),("event","stopped")]
-}