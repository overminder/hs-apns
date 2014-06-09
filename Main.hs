{-# LANGUAGE PackageImports #-}

import Control.Applicative
import "mtl" Control.Monad.State.Strict
import Control.Concurrent.STM
import Control.Concurrent.Async
import Control.Concurrent hiding (yield)
import qualified Data.Text as T
import qualified Data.Vector as V
import Network
import Network.TLS
import "tls" Network.TLS.Extra
import Data.Time
import Data.Default

import Pipes
import qualified Pipes.Prelude as P
import qualified Pipes.Attoparsec as PA
import qualified Pipes.Concurrent as PC
import qualified Data.Attoparsec as A
import qualified Data.Attoparsec.Binary as A
import qualified Data.Serialize as S
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC8
import qualified Data.ByteString.UTF8 as BU8
import qualified Data.ByteString.Base16 as B16
import Data.Word
import System.IO
import System.Environment
import System.Exit

import Types
import Send
import ConnectionPool

mkApnsConf = do
  [certPath, keyPath, gwHost, gwPort] <- replicateM 4 await

  Right cred <- liftIO $ credentialLoadX509 certPath keyPath
  let
    tlsParam = ClientParams {
      clientUseMaxFragmentLength = Nothing,
      clientServerIdentification = (gwHost, B.empty),
      clientUseServerNameIndication = False,
      clientWantSessionResume = Nothing,
      clientShared = def {
        sharedCredentials = Credentials [cred]
      },
      clientHooks = def {
        onCertificateRequest = const $ return $ Just cred,
        onServerCertificate = \ _ _ _ _ -> return []
        -- ^ This one.
      },
      clientSupported = def {
        supportedCiphers = ciphersuite_all
      }
    }

  let conf' = ApnsConf tlsParam gwHost (read gwPort) 5000000 undefined
      mkConn = evalSendM connectApns conf'
  pool <- liftIO $ mkPool mkConn 5
  let conf = conf' { acConnPool = pool}

  return conf

readMessageInput fromInput = P.toListM $ fromInput >-> parseLines 0
 where
  parseLines i = do
    token <- concat . words <$> await -- to de-space
    payload <- await
    expiry <- lift $ addUTCTime 3600 <$> getCurrentTime
    yield $ Message (T.pack token) i (T.pack payload)
                    expiry Conservely
    parseLines (i + 1)

logWith tag = forever $ do
  x <- await
  liftIO $ putStrLn $ tag ++ show x
  yield x

main = do
  -- XXX
  hSetBuffering stdout NoBuffering

  args <- getArgs
  fromFile <- case args of
    ["-"] -> return P.stdinLn
    [filePath]
      | filePath `notElem` ["-h", "--help"] ->
          P.fromHandle <$> openFile filePath ReadMode
    _ -> error $ unlines [ "usage: [this-program] batch-file"
                         , " where batch-file's format is:"
                         , "<cert-path> '\\n'"
                         , "<key-path> '\\n'"
                         , "<apns-gateway-host> '\\n'"
                         , "<apns-gateway-port> '\\n'"
                         , "<message>*"
                         , " where message's format is:"
                         , "<token-in-base64> '\\n'"
                         , "<payload> '\\n'"]
  -- We just ignore feedback since connecting to the feedback service
  -- might interfere with UAT feedback service.
  conf <- runEffect $ (fromFile >> return undefined) >-> mkApnsConf
  msgs <- V.fromList <$> readMessageInput fromFile

  resizePool 10 (acConnPool conf)
  
  resps <- send conf msgs
  print resps
  return ()

