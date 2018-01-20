{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns      #-}

module Main where

import Control.Distributed.Taskell
import Control.Monad.IO.Class
import qualified Data.ByteString.Lazy as BL
import Data.Store

deserialize :: Store a => BL.ByteString -> a
deserialize = decodeEx . BL.toStrict

printL :: (MonadIO m, Show a) => a -> m ()
printL = liftIO . print

main :: IO ()
main = logger defaultLoger $ connection "localhost" "/" "guest" "guest" $ do
  channel "task" $ do
    task1 <- enqueueTask "taskell.q1" "additionTask" $ BL.fromStrict $ encode (1 :: Int, 2 :: Int)
    task1 `onProgress` \(deserialize -> p) -> printL (p :: Int)
    task1 `onResult` \(deserialize -> r) -> do
      task2 <-  enqueueTask "taskell.q1" "dummyTask" $ BL.fromStrict $ encode (r :: Int)
      task2 `onResult` \(deserialize -> p) -> printL (p :: Int)