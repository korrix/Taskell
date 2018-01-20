{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts  #-}

module Control.Distributed.Taskell.Client where

import qualified Data.Text as T
import qualified Data.ByteString.Lazy as BL
import Control.Distributed.Taskell.AMQP
import Control.Monad.Reader

import Data.Monoid
import Data.UUID
import Data.UUID.V4

enqueueTask :: (MonadIO m, MonadReader (Env Channel) m) => T.Text -> T.Text -> BL.ByteString -> m UUID
enqueueTask qname taskName taskArgs = do
  taskId <- liftIO nextRandom
  queue newQueue {queueName = qname, queueDurable = False, queueExclusive = True} $ do
    publish newMsg { msgBody = taskArgs
                    , msgID = Just $ toText taskId
                    , msgType = Just taskName
                    , msgDeliveryMode = Just Persistent }
  return taskId

onSuffix :: (MonadIO m, MonadReader (Env Channel) m) 
         => T.Text -> UUID -> (BL.ByteString -> ReaderT (Env Channel) IO ()) -> m () 
onSuffix suffix taskId callback = do
  env <- ask
  queue newQueue {queueName = toText taskId <> suffix, queueAutoDelete = True} $
    subscribe Ack $ do
      Env r _ (msg, envelope) <- ask
      deferAck r envelope
      liftIO $ runReaderT (callback $ msgBody msg) env
  return ()

onProgress :: (MonadIO m, MonadReader (Env Channel) m) 
           => UUID -> (BL.ByteString -> ReaderT (Env Channel) IO ()) -> m () 
onProgress = onSuffix ".progress"

onResult :: (MonadIO m, MonadReader (Env Channel) m) 
         => UUID -> (BL.ByteString -> ReaderT (Env Channel) IO ()) -> m () 
onResult = onSuffix ".result"