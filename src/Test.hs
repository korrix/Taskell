{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RankNTypes                #-}
module Test where

import Data.Store
import Data.Text
import Data.ByteString
import Data.HashMap.Strict

newtype Task = Task { runTask :: forall a b . (Store a, Store b) => a -> IO b }

registeredTasks :: HashMap Text Task
registeredTasks = fromList []

-- runTaskByName :: Text -> ByteString -> IO ByteString
-- runTaskByName taskName encodedArg = do
--   arg <- decodeIO encodedArg -- wyinferowano typ arg :: a0
--   result <- runTask (registeredTasks ! taskName) arg -- wyinferowao typ result :: a1
--   -- Nie można zunifikować a0 z a1, błąd niejednoznaczności typów
--   return $ encode result

myshow :: Show a => a -> String
myshow = undefined

myread :: String -> a
myread = undefined

test = myshow (myread "5")