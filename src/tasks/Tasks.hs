{-# LANGUAGE OverloadedStrings      #-}

module Tasks ( registeredTasks ) where

import Control.Distributed.Taskell
import qualified Data.ByteString.Lazy as BL
import Control.Monad
import Data.Store

mkRawTask :: (Store arg, Store p, Store res) => Task arg p res -> RawTask
mkRawTask = toRawTask (decodeEx . BL.toStrict) 
                      (BL.fromStrict . encode)
                      (BL.fromStrict . encode)

registeredTasks :: TaskStore
registeredTasks = fromList [ ("additionTask", mkRawTask additionTask)
                           , ("multiplicationTask", mkRawTask multiplicationTask)
                           ]

additionTask :: Task (Int, Int) () Int
additionTask = Task $ \(a, b) -> return $ a + b

multiplicationTask :: Task (Double, Double) () Double
multiplicationTask = Task $ \(a, b) -> return $ a * b

summationTask :: Task [Int] Int Int
summationTask = Task $ \numbers -> 
  let indexedNumbers = zip numbers [1..]
      count = fromIntegral $ length numbers
      sumf acc (a, nr) = do
        progress $ floor $ (fromIntegral nr / count) * 100
        return $ acc + a
  in foldM sumf (0 :: Int) indexedNumbers