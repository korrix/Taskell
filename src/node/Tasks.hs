{-# LANGUAGE OverloadedStrings      #-}
{-# LANGUAGE DataKinds              #-}
{-# LANGUAGE TypeOperators          #-}
{-# LANGUAGE TypeFamilies           #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE UndecidableInstances   #-}
{-# LANGUAGE ScopedTypeVariables    #-}

module Tasks ( registeredTasks ) where

import Control.Distributed.Taskell
import Data.HashMap.Strict
import Data.Text
import Data.Store

mkRawTask :: (Store a, Store b) => (a -> IO b) -> RawTask
mkRawTask fn = RawTask $ \arg -> encode <$> (decodeIO arg >>= fn)

registeredTasks :: HashMap Text RawTask
registeredTasks = fromList [("additionTask", mkRawTask additionTask)
                           ,("multiplicationTask", mkRawTask multiplicationTask)
                           ]

additionTask :: (Int, Int) -> IO Int
additionTask (a, b) = return $ a + b

multiplicationTask :: (Double, Double) -> IO Double
multiplicationTask (a, b) = return $ a * b