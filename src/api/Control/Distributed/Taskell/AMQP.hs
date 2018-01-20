{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}

module Control.Distributed.Taskell.AMQP (
    module Control.Distributed.Taskell.AMQP
  , AMQP.Channel
  , AMQP.Connection
  , AMQP.Ack(..)
  , AMQP.QueueOpts(..)
  , AMQP.ExchangeOpts(..)
  , AMQP.Message(..)
  , AMQP.Envelope(..)
  , AMQP.DeliveryMode(..)
  , AMQP.newQueue
  , AMQP.newExchange
  , AMQP.newMsg
  ) where

import Prelude hiding ( log )

import Data.Monoid
import Control.Concurrent
import Control.Monad.Loops
import Control.Monad.Reader
import Control.IO.Region
import System.Log.FastLogger
import Control.Concurrent.STM

import qualified Network.AMQP as AMQP
import qualified Data.Text    as T
import qualified Data.ByteString.Lazy as BL
  
data Env a = Env { _region :: Region
                 , _log :: forall m . MonadIO m => T.Text -> m ()
                 , _res :: a
                 }

defaultLoger :: IO LoggerSet
defaultLoger = newStdoutLoggerSet defaultBufSize

logger :: MonadIO m => IO LoggerSet -> ReaderT (T.Text -> IO ()) m b -> m b
logger mkLog body = do
  log <- liftIO mkLog
  let logFn :: T.Text -> IO ()
      logFn = pushLogStrLn log . toLogStr
  runReaderT body logFn 

connection :: (MonadIO m, MonadReader (T.Text -> IO ()) m) 
           => String -> T.Text -> T.Text -> T.Text
           -> ReaderT (Env AMQP.Connection) IO b -> m b
connection host vhost username password body = do
  logFn <- ask
  liftIO $ region $ \r -> do
    conn <- alloc_ r 
      (do logFn ("Connecting to " <> T.pack host)
          AMQP.openConnection host vhost username password)
      (\c -> logFn ("Disconnecting from " <> T.pack host) >> AMQP.closeConnection c)
    runReaderT body $ Env r (liftIO . logFn) conn

channel :: (MonadIO m, MonadReader (Env AMQP.Connection) m) 
        => T.Text -> ReaderT (Env AMQP.Channel) m b -> m b
channel name body = do
  Env r log conn <- ask
  chan <- liftIO $ alloc_ r 
    (log ("Opening " <> name <> " channel") >> AMQP.openChannel conn) 
    (\c -> log ("Closing " <> name <> " channel") >> AMQP.closeChannel c)
  runReaderT body $ Env r log chan

parallelism :: (MonadReader (Env AMQP.Channel) m, MonadIO m) => Integer -> m ()
parallelism p = do
  Env _ _ chan <- ask
  liftIO $ AMQP.qos chan 0 (fromInteger p) True

queue :: (MonadIO m, MonadReader (Env AMQP.Channel) m) 
      => AMQP.QueueOpts -> ReaderT (Env (AMQP.Channel, T.Text)) m b -> m b
queue queueDecl body = do
  Env r log chan <- ask
  (queueName, _, _) <- liftIO $ do 
    log $ "Declaring queue " <> AMQP.queueName queueDecl
    AMQP.declareQueue chan queueDecl
  runReaderT body $ Env r log (chan, queueName)

exchange :: (MonadIO m, MonadReader (Env AMQP.Channel) m) 
         => AMQP.ExchangeOpts -> m T.Text
exchange exchangeDecl = do
  Env _ log chan <- ask
  liftIO $ do
    log $ "Declaring exchange " <> AMQP.exchangeName exchangeDecl
    AMQP.declareExchange chan exchangeDecl
  return $ AMQP.exchangeName exchangeDecl

bindTo :: (MonadIO m, MonadReader (Env (AMQP.Channel, T.Text)) m) 
       => T.Text -> T.Text -> m ()
bindTo exchangeName routingKey = do
  Env r log (chan, queueName) <- ask
  liftIO $ alloc_ r 
    (do log $ "Binding queue " <> queueName <> " to " <> exchangeName
        AMQP.bindQueue chan queueName exchangeName routingKey)
    (\_ -> do log $ "Unbinding queue " <> queueName <> " from " <> exchangeName
              AMQP.unbindQueue chan queueName exchangeName routingKey)
  
subscribe :: (MonadReader (Env (AMQP.Channel, T.Text)) m, MonadIO m) 
          => AMQP.Ack -> ReaderT (Env (AMQP.Message, AMQP.Envelope)) IO () -> m AMQP.ConsumerTag
subscribe ack callback = do
  Env r log (chan, queueName) <- ask
  let handler msg = region $ \r' -> runReaderT callback (Env r' log msg)

  liftIO $ alloc_ r (do log $ "Consuming messages from queue " <> queueName
                        AMQP.consumeMsgs chan queueName ack handler)
                    (\ct -> do log $ "Stoping consumer on queue " <> queueName
                               AMQP.cancelConsumer chan ct)

withConnection :: MonadReader (Env a1) m => a2 -> ReaderT (Env a2) m b -> m b
withConnection conn body = do
  Env r log _ <- ask
  runReaderT body $ Env r log conn

publishAsyncFrom :: MonadIO m => TMVar (Maybe BL.ByteString) -> ReaderT (Env (AMQP.Channel, T.Text)) m ThreadId
publishAsyncFrom source = do
  (chan, queueName) <- asks _res
  liftIO $ forkIO $ whileJust_ (atomically $ takeTMVar source) $ \val ->
    AMQP.publishMsg chan "" queueName AMQP.newMsg {AMQP.msgBody = val, AMQP.msgDeliveryMode = Just AMQP.Persistent}

publish :: (MonadIO m, MonadReader (Env (AMQP.Channel, T.Text)) m) 
        => AMQP.Message -> m ()
publish msg = do
  (chan, queueName) <- asks _res
  liftIO $ AMQP.publishMsg chan "" queueName msg
  return ()

deferAck :: MonadIO m => Region -> AMQP.Envelope -> m ()
deferAck r env = liftIO $ defer r (AMQP.ackEnv env)

innerRegion :: (MonadIO m, MonadReader (Env a) m) => ReaderT (Env a) IO b -> m b
innerRegion body = do
  Env _ log res <- ask
  liftIO $ region $ \r -> runReaderT body (Env r log res)