{-# LANGUAGE TemplateHaskell #-}
module Control.Distributed.Taskell.Task where

import Data.ByteString
import TH.Derive
import Data.Store
import Data.UUID

data RawTask = RawTask { runTaskIO :: ByteString -> IO ByteString }

newtype TaskAbort = TaskAbort { abortTaskId :: UUID 
                              } deriving Show

$($(derive [d| instance Deriving (Store UUID) |]))
$($(derive [d| instance Deriving (Store TaskAbort) |]))