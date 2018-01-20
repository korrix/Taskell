{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}

module Main where

import Prelude hiding (log)

import qualified Data.ByteString.Lazy   as BL
import qualified STMContainers.Map      as STM
import qualified Control.Concurrent.STM as STM
import qualified Focus                  as STM.Focus

import Control.Distributed.Taskell hiding (progress)
import Control.Concurrent
import Control.Monad.Reader
import Data.Monoid

import Data.UUID

import Tasks

atomically :: MonadIO m => STM.STM a -> m a
atomically = liftIO . atomically

type CurrentTasks = STM.Map UUID ThreadId

abortHandler :: CurrentTasks -> ReaderT (Env (Message, Envelope)) IO ()
abortHandler currentTasks = do
  Env r log (msg, env) <- ask
  deferAck r env

  let Just taskId = fromASCIIBytes $ BL.toStrict (msgBody msg)
  log $ "Got abort for task " <> toText taskId

  abortCurrent <- atomically $ STM.focus (\k -> return $ (k, STM.Focus.Remove)) taskId currentTasks
  case abortCurrent of
    Just threadId -> do
       liftIO $ killThread threadId
       log "Abort received, thread killed"
    Nothing -> log "Abort received, skipping"


taskHandler :: Connection -> ReaderT (Env (Message, Envelope)) IO ()
taskHandler conn = do
  Env r log (msg, env) <- ask
  deferAck r env

  let Just taskId   = msgID msg
  let Just taskName = msgType msg
  let taskArgs      = msgBody msg

  log $ "Processing task " <> taskId <> " of type " <> taskName

  (result, progress) <- atomically $ (,) <$> STM.newEmptyTMVar <*> STM.newEmptyTMVar

  withConnection conn $
    forM_ [(".result", result), (".progress", progress)] $ \(suffix, mvar) ->
      channel (taskId <> suffix) 
        $ queue newQueue {queueName = taskId <> suffix, queueAutoDelete = True}  
        $ publishAsyncFrom mvar
  
  let save var = atomically . STM.putTMVar var
  res <- runTaskByName registeredTasks taskName taskArgs (save progress . Just)
  save progress Nothing
  save result (Just res)
  save result Nothing

  return ()

main :: IO ()
main = do
  currentTasks <- STM.newIO
  logger defaultLoger $ connection "localhost" "/" "guest" "guest" $ do
    channel "abort" $ do
      abortEx <- exchange newExchange {exchangeName = "taskell.abort", exchangeType = "fanout"}
      queue newQueue {queueName = "", queueDurable = False, queueExclusive = True} $ do
        bindTo abortEx ""
        subscribe Ack $ abortHandler currentTasks

    conn <- asks _res
    channel "task" $ do
      parallelism 1
      forM_ ["taskell.q1", "taskell.q2"] $ \q ->
        queue newQueue {queueName = q} $ do
          subscribe Ack $ taskHandler conn
      
    liftIO $ do
      putStrLn "Press any key to terminate..."
      getLine
      return ()