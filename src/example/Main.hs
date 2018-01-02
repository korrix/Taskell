{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Distributed.Taskell

main :: IO ()
main = withRabbit "src/taskell.conf" $ \connection -> do
  channel <- openChannel connection
  taskId <- enqueueTask channel "" "taskell.q1" "additionTask" (5 :: Int, 6 :: Int)
  result <- awaitResult channel taskId
  putStrLn $ "Result: " ++ show (result :: Int)