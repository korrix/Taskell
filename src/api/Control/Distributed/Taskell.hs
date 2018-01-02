{-# LANGUAGE OverloadedStrings #-}

module Control.Distributed.Taskell 
  ( module Control.Distributed.Taskell.Task
  , module Control.Distributed.Taskell
  , openChannel
  , Connection
  , Channel
  ) where

import Control.Distributed.Taskell.Task
import Control.Concurrent.STM

import qualified Data.Text as T

import qualified Data.ByteString.Lazy as BL
import Data.Configurator as Cfg

import Network.AMQP
import Data.Store

import Data.UUID
import Data.UUID.V4

import Control.Exception (bracket)

withRabbit :: String -> (Connection -> IO a) -> IO a
withRabbit configPath handler = do
  config <- load [ Required configPath ]
  host     <- lookupDefault "localhost" config "taskell.rabbitmq.host"
  vhost    <- lookupDefault "//"        config "taskell.rabbitmq.vhost"
  username <- lookupDefault "guest"     config "taskell.rabbitmq.username"
  password <- lookupDefault "password"  config "taskell.rabbitmq.password"
  -- abortExchange <- lookupDefault "taskell.abort" config "taskell.abortExchange"
  bracket (openConnection host vhost username password) closeConnection handler

enqueueTask :: Store a => Channel -> T.Text -> T.Text -> T.Text -> a -> IO UUID  
enqueueTask taskChannel exchange key taskType taskArgs = do 
  randomUUID <- nextRandom
  _ <- publishMsg taskChannel exchange key
        newMsg {msgBody = (BL.fromStrict $ encode taskArgs),
                msgID = Just $ toText randomUUID,
                msgType = Just taskType,
                msgDeliveryMode = Just Persistent}
  return randomUUID

awaitResult :: Store b => Channel -> UUID -> IO b
awaitResult taskChannel taskId = do
  (taskResultQueue, _, _) <- declareQueue taskChannel newQueue {
      queueName = T.append (toText taskId) ".results"
    , queueAutoDelete = True
  }

  resultVar <- atomically newEmptyTMVar
  tag <- consumeMsgs taskChannel taskResultQueue NoAck $ \(msg, _) -> do
    res <- decodeIO $ BL.toStrict (msgBody msg)
    atomically $ putTMVar resultVar res
    return () 
  result <- atomically $ takeTMVar resultVar
  cancelConsumer taskChannel tag
  return result
  -- getMsg taskResultQueue NoAck $ 
-- setupAborts :: CurrentTasks -> Cfg.Config -> Channel -> IO ConsumerTag
-- setupAborts currentTasks config abortChannel = do
--   abortExchange <- lookupDefault "taskell.abort" config "taskell.abortExchange"
--   (abortQueue, _, _) <- declareQueue abortChannel newQueue {queueName = "", queueDurable = False, queueExclusive = True}
--   _ <- declareExchange abortChannel newExchange {exchangeName = abortExchange, exchangeType = "fanout"}
--   bindQueue abortChannel abortQueue abortExchange ""
--   consumeMsgs abortChannel abortQueue Ack $ processAbort currentTasks