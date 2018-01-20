module Control.Distributed.Taskell.Task (
    module Control.Distributed.Taskell.Task
  , HM.fromList
) where

import Data.HashMap.Strict as HM
import Data.Text
import Data.ByteString.Lazy
import Control.Monad.Trans
import Control.Monad.Coroutine
import Control.Monad.Coroutine.SuspensionFunctors

newtype Task arg p r = Task { runTask :: arg -> Coroutine (Yield p) IO r }
type RawTask = Task ByteString ByteString ByteString

instance Functor (Task arg p) where
  fmap f (Task t) = Task $ \arg -> fmap f (t arg)

instance Applicative (Task arg p) where
  pure t = Task $ \_ -> pure t
  Task t1 <*> Task t2 = Task $ \arg -> t1 arg <*> t2 arg

instance Monad (Task arg p) where
  (Task t) >>= f = Task $ \arg -> do
    t' <- t arg
    runTask (f t') arg 

type TaskStore = HashMap Text RawTask

runTaskByName :: MonadIO m => TaskStore -> Text -> ByteString -> (ByteString -> IO a) -> m ByteString
runTaskByName ts key arg reportFn = liftIO $ do
  let producer = runTask (ts ! key) arg
  pogoStick (\(Yield x cont) -> lift (reportFn x) >> cont) producer

progress :: Monad m => p -> Coroutine (Yield p) m ()
progress = yield

toRawTask :: (ByteString -> arg) -> (p -> ByteString) -> (r -> ByteString)
          -> Task arg p r -> RawTask
toRawTask argDecodeFn progressEncodeFn resultEncodeFn task = Task $ \arg -> do
  let t = runTask task (argDecodeFn arg)
  r <- mapSuspension (\(Yield x y) -> Yield (progressEncodeFn x) y) t 
  return $ resultEncodeFn r