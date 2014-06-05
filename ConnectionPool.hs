{-# LANGUAGE ScopedTypeVariables, NoMonomorphismRestriction #-}

module ConnectionPool where

import Control.Applicative
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Catch
import Control.Exception (AsyncException(..))
import Control.Concurrent
import Control.Concurrent.Async

data ConnPool a
  = ConnPool {
    cpWorkers :: MVar [Async ()],
    cpChan :: ConnChan a,
    cpMkConn :: IO a
  }

type ConnChan a = Chan (a, IO ())

spawnOne :: IO a -> ConnChan a -> IO ()
spawnOne m out = do
  lock <- newEmptyMVar
  loop lock
 where
  loop lock = do
    eiA <- try m
    case eiA of
      Right a -> do
        writeChan out (a, putMVar lock ())  -- make idempotent?
        takeMVar lock  -- blocked until consumed
        loop lock
      Left ThreadKilled -> return () -- Done
      Left _ -> loop lock

mkPool :: IO a -> Int -> IO (ConnPool a)
mkPool mkConn limit = do
  pool <- ConnPool <$> newMVar [] <*> newChan <*> pure mkConn
  resizePool limit pool
  return pool

-- Worker

resizePool :: Int -> ConnPool a -> IO ()
resizePool newSiz pool = modifyMVar_ (cpWorkers pool) $ \ workers -> do
  let
    oldSiz = length workers
  if newSiz > oldSiz
    then do
      newWorkers <- replicateM (newSiz - oldSiz)
                               (async (spawnOne (cpMkConn pool) (cpChan pool)))
      return (workers ++ newWorkers)
    else do
      let nDrops = oldSiz - newSiz
      forM_ (take nDrops workers) $ \ w -> do
        async $ cancel w
      return $ drop nDrops workers

withPool :: (MonadIO m, MonadCatch m) => ConnPool a -> (a -> m b) -> m b
withPool pool mf = do
  bracket (getFromPool pool)
          (\ (_, onDone) -> liftIO $ onDone)
          (\ (conn, _) -> mf conn)

getFromPool = liftIO . readChan . cpChan

