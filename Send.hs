{-# LANGUAGE ScopedTypeVariables #-}

module Send where

import Control.Applicative
import Control.Exception
import Control.Concurrent
import Control.Concurrent.Async
import Control.Monad.RWS.Strict
import Control.Monad.State.Strict
import qualified Data.ByteString as B
import Crypto.Random.AESCtr
import Data.IORef
import Data.Certificate.X509
import qualified Data.Vector as V
import Network
import Network.TLS
import Network.TLS.Extra
import Pipes
import qualified Pipes.Network.TCP.TLS as PT
import qualified Pipes.Attoparsec as PA
import System.Timeout

import Types
import ConnectionPool

-- Things to consider:
--
-- 1. Reliability. Message should either be sent, or failed sending.
--    Various kinds of retries need to be done inside send.
--    - Pre-send: check response status. If got response, re-conn and
--      resend from error msg. Otherwise go ahead.
--
--    - Exception during send: again check response first. If no resp
--      or resp recv got exception too, then send batch again (?)
--
--    - Exception during recv: hmm, send batch again (??)
--
--    - post-sends: wait for predefined seconds
--
--    1.1 Retries
--
--        We cannot retry indefinitely -- limited times, exponential
--        backup, etc need to be used.
--
-- 2. Implications
--
--    - Msg is assumed to have their ident set to be the index
--      in the vector.
--
-- 3. Hacks:
--    
--    - It seems that adding an invalid message in the back can drastically
--      improve the throughoutput since apns will immediately return an
--      response and therefore there's no need to wait.

data ApnsConf
  = ApnsConf {
    acTlsParam    :: Params,
    acHost        :: String,
    acPort        :: Int,
    acRespTimeout :: Int, -- Milliseconds
    acConnPool    :: ConnPool Context
  }

type BsProdIO = Producer B.ByteString IO ()
type BsConsIO = Consumer B.ByteString IO ()

send
  :: ApnsConf
  -> V.Vector Message
  -> IO [Response]
send conf ms = snd <$> evalRWST (send' Nothing ms 0) conf ()

evalSendM m conf = fst <$> evalRWST m conf ()

type SendM a = RWST ApnsConf [Response] () IO a

send'
  :: Maybe (BsProdIO, BsConsIO, IO ())
     -- SSL recv/send/close, or Nothing if conn is not established
  -> V.Vector Message           -- Messages to be sent
  -> Int                        -- Current index of msgs to be sent
  -> SendM ()
send' _ ms ix
  | ix >= V.length ms = return ()

send' Nothing ms ix = do
  liftIO $ putStrLn "Connecting..."
  (ctx, onDone) <- getFromPool =<< asks acConnPool
  liftIO $ putStrLn "Ok"
  let
    closeCtx = try $ contextClose ctx :: IO (Either SomeException ())
    ctx' = (PT.fromContext ctx, PT.toContext ctx, closeCtx >> onDone)
  send' (Just ctx') ms ix

send' ctxIO@(Just (fromCtx, toCtx, closeCtx)) ms ix = do
  timeoutMs <- asks acRespTimeout

  join $ liftIO $ do
    -- The current response. Nothing means resp is not received yet
    rResp <- newIORef Nothing

    -- Start send/recv loop
    tSend <- async $ sendOnce toCtx ms ix rResp
    tRecv <- async $ recvResp fromCtx rResp

    -- Check for tSend, see sendOnce for possible outcomes
    sendRes <- waitCatch tSend
    -- Add a timeout to tRecv after tSend is done
    async $ do
      threadDelay timeoutMs
      cancel tRecv

    -- Checking for tSend and tRecv's exception status.
    --
    -- [IOException] means that the underlying SSL transport
    -- is broken and a reconnection is needed.
    --
    -- [ApnsException] currently only has one instance -- responseParseError.
    -- This also means that SSL transport is broken.
    --
    -- [AsyncException] (ThreadKilled) means that tRecv went timeout before
    -- any response is received. This doesn't tell us anything about the
    -- SSL transport though.
    ctxIO' <- case sendRes of
      Left e -> do
        putStrLn $ "[send'.tSend] " ++ show e
        throwIO e `catch` (\ (e :: IOException) -> do
          -- Should be socket error
          return Nothing)
      Right _ -> do
        return ctxIO

    -- Check for tRecv, see recvResp for possible outcomes
    recvRes <- waitCatch tRecv
    ctxIO'' <- case recvRes of
      Left e -> do
        putStrLn $ "[send'.tRecv] " ++ show e
        throwIO e `catches`
          [ Handler $ \ (e :: AsyncException) -> case e of
              ThreadKilled ->
                -- No response, rResp should be Nothing
                -- recv side think ctx is still usable
                return ctxIO'

            -- IOE: ctx failure
          , Handler $ \ (e :: IOException) -> return Nothing

            -- Parse error: ctx failure
          , Handler $ \ (e :: ApnsException) -> return Nothing
          ]
      Right _ -> return ctxIO'

    mbResp <- readIORef rResp
    case (ctxIO'', mbResp) of
      (_, Just resp) -> return $ do
        -- got resp: skip this msg, record the resp and
        -- go ahead with a new connection
        tell [resp]
        liftIO $ putStrLn $ "[send'.case] Skip this one due to " ++ show resp
        liftIO $ closeCtx
        send' Nothing ms (resIdent resp + 1)

      (Just _, _) -> return $ do
        -- Conn is fine and no resp: success!
        liftIO $ closeCtx
        return ()

      (Nothing, _) -> return $ do
        -- Disconn and no resp: complete retry
        liftIO $ closeCtx
        send' Nothing ms ix

-- Either send all,
-- or got socket error,
-- or got resp and abort
sendOnce
  :: BsConsIO
  -> V.Vector Message
  -> Int
  -> IORef (Maybe Response)
  -> IO ()
sendOnce toCtx ms ix mResp = go ix
 where
  go i
    | i >= mLen = return ()
    | otherwise = do
        putStrLn $ "[sendOnce.go] Sending msgs[" ++ show i ++
                   "] of " ++ show mLen
        mbResp <- readIORef mResp
        case mbResp of
          Nothing -> do
            runEffect $ fromMessage (ms V.! i) >-> toCtx
            go (i + 1)
          Just _  -> return ()
  mLen = V.length ms

-- Either timeout,
-- or got resp,
-- or got io error (socket or parse)
recvResp
  :: BsProdIO
  -> IORef (Maybe Response)
  -> IO ()
recvResp fromCtx rResp = do
  eiRes <- (`evalStateT` fromCtx) $ PA.parse parseResponse
  case eiRes of
    Nothing ->
      throwIO (ResponseParseError "Exhausted")
    Just (Left e) ->
      -- XXX: parse error lol?
      throwIO (ResponseParseError $ show e)
    Just (Right resp) ->
      atomicWriteIORef rResp (Just resp)

connectApns :: SendM Context
connectApns = do
  host <- asks acHost
  port <- asks acPort
  tlsParam <- asks acTlsParam
  liftIO $ do
    h <- connectTo host (PortNumber $ fromIntegral port)
    rng <- makeSystem
    ctx <- contextNewOnHandle h tlsParam rng
    handshake ctx
    return ctx

