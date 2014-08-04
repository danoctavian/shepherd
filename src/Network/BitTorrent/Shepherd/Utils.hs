{-# LANGUAGE NoMonomorphismRestriction #-}
module Network.BitTorrent.Shepherd.Utils where
import Control.Monad
import Prelude as P

-- UTILS
if' c a b = if c then a else b

maybeToEither :: a -> Maybe b -> Either a b
maybeToEither errorValue = maybe (Left errorValue) (\x -> Right x)

liftMaybe :: (MonadPlus m) => Maybe a -> m a
liftMaybe = maybe mzero return

(.*) :: (c -> d) -> (a -> b -> c) -> (a -> b -> d)
(.*) = (.) . (.)

(.**) :: (d -> e) -> (a -> b -> c -> d) -> (a -> b -> c -> e)
(.**) = (.) . (.*)

