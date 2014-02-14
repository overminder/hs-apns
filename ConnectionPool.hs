{-# LANGUAGE ScopedTypeVariables, NoMonomorphismRestriction #-}

module ConnectionPool where

import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Catch
import Control.Concurrent
import Control.Concurrent.Async


type ConnPool a = Chan (a, IO ())

spawnOne m out = do
  lock <- newEmptyMVar
  forever $ do
    eiA <- try m
    case eiA of
      Right a -> do
        writeChan out (a, putMVar lock ())  -- make idempotent?
        takeMVar lock  -- blocked until consumed
      Left (e :: SomeException) -> return () -- retry

mkPool mkConn limit = do
  out <- newChan
  replicateM_ limit (async (spawnOne mkConn out))
  return out

-- Worker

withPool :: (MonadIO m, MonadCatch m) => ConnPool a -> (a -> m b) -> m b
withPool pool mf = do
  bracket (liftIO $ readChan pool)
          (\ (_, onDone) -> liftIO $ onDone)
          (\ (conn, _) -> mf conn)

getFromPool = liftIO . readChan
