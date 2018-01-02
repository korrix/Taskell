{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
module Main where

import Control.Monad

import qualified Data.Text as T

import qualified Data.Configurator.Types as Cfg
import Data.Configurator as Cfg

import Network.AMQP
import Data.Store
import Data.UUID
import qualified Data.ByteString.Lazy as BL
import Data.HashMap.Strict ((!))
import Options.Applicative

import Control.Concurrent
import qualified Control.Monad.STM as STM
import qualified STMContainers.Map as STM
import qualified Focus as STM.Focus

import Control.Distributed.Taskell

import Tasks

type CurrentTasks = STM.Map UUID ThreadId 
newtype Options = Options { configPath :: String } deriving Show

decodeMsg :: Store a => Message -> IO a
decodeMsg msg = decodeIO (BL.toStrict $ msgBody msg)

processTask :: CurrentTasks -> Channel -> (Message, Envelope) -> IO ()
processTask currentTasks taskChannel (msg, env) = do
  let Just taskName = msgType msg
  let Just taskId = msgID msg
  let taskArgs = BL.toStrict $ msgBody msg

  print $ T.append "Received task " taskId
  (taskResultQueue, _, _) <- declareQueue taskChannel newQueue {
      queueName = T.append taskId ".results"
    , queueAutoDelete = True
  }

  -- (taskErrorQueue, _, _) <- declareQueue taskChannel newQueue {
  --   queueName = T.append taskId ".errors"
  -- , queueAutoDelete = True
  -- }

  print $ T.append "Szatan czyste zło: " taskResultQueue 
  taskThread <- forkIO $ do
    putStrLn "Forking"
    taskResult <- runTaskIO (registeredTasks ! taskName) taskArgs
    _ <- publishMsg taskChannel "" taskResultQueue
        newMsg {msgBody = BL.fromStrict taskResult, msgDeliveryMode = Just Persistent}
    putStrLn "Responding with result"
    return ()

  let Just uuid = fromText taskId
  STM.atomically $ STM.insert taskThread uuid currentTasks

  ackEnv env

processAbort :: CurrentTasks -> (Message, Envelope) -> IO ()
processAbort currentTasks (msg, env) = do
  TaskAbort taskId <- decodeMsg msg
  abortCurrent <- STM.atomically $ STM.focus (\k -> return $ (k, STM.Focus.Remove)) taskId currentTasks
  case abortCurrent of
    Just threadId -> do
       killThread threadId
       putStrLn "Abort received, thread killed"
    Nothing -> return ()
  ackEnv env

rabbitConnect :: Cfg.Config -> IO Connection
rabbitConnect config = do
  host     <- lookupDefault "localhost" config "taskell.rabbitmq.host"
  vhost    <- lookupDefault "//"        config "taskell.rabbitmq.vhost"
  username <- lookupDefault "guest"     config "taskell.rabbitmq.username"
  password <- lookupDefault "password"  config "taskell.rabbitmq.password"
  openConnection host vhost username password

setupAborts :: CurrentTasks -> Cfg.Config -> Channel -> IO ConsumerTag
setupAborts currentTasks config abortChannel = do
  abortExchange <- lookupDefault "taskell.abort" config "taskell.abortExchange"
  (abortQueue, _, _) <- declareQueue abortChannel newQueue {queueName = "", queueDurable = False, queueExclusive = True}
  _ <- declareExchange abortChannel newExchange {exchangeName = abortExchange, exchangeType = "fanout"}
  bindQueue abortChannel abortQueue abortExchange ""
  consumeMsgs abortChannel abortQueue Ack $ processAbort currentTasks

setupTasks :: CurrentTasks -> Cfg.Config -> Connection -> IO [ConsumerTag]
setupTasks currentTasks config connection = do
  taskChannel <- openChannel connection

  parallelism <- lookupDefault 1  config "taskell.parallelism"
  qos taskChannel 0 parallelism True -- Defining how many tasks at once can be processed
  queues <- lookupDefault ["taskell.tasks"] config "taskell.queues"

  forM queues $ \queue -> do
    putStrLn $ "Subscirbing " ++ T.unpack queue
    taskManagementChannel <- openChannel connection
    _ <- declareQueue taskChannel newQueue {queueName = queue}
    consumeMsgs taskChannel queue Ack $ processTask currentTasks taskManagementChannel

main :: IO ()
main = 
  let parser = Options <$> argument str (metavar "CONFIG_PATH")
  in execParser (info parser mempty) >>= \(Options cp) -> do
      config <- load [ Required cp ]
      connection <- rabbitConnect config
    
      currentTasks <- STM.newIO

      abortChannel <- openChannel connection
      _ <- setupAborts currentTasks config abortChannel
      
      _ <- setupTasks currentTasks config connection
    
      _ <- getLine
    
      closeConnection connection
    