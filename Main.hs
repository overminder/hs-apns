import Control.Applicative
import Control.Monad.State.Strict
import Control.Concurrent.STM
import Control.Concurrent.Async
import Control.Concurrent hiding (yield)
import qualified Data.Text as T
import qualified Data.Vector as V
import Network
import Network.TLS
import Network.TLS.Extra
import System.Time
import System.Time.Utils
import Data.Time

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

  cert <- liftIO $ fileReadCertificate certPath
  key <- liftIO $ fileReadPrivateKey keyPath
  let
    p12 = [(cert, Just key)]
    tlsParam = defP {
      pCiphers = ciphersuite_all,
      pCertificates = p12,
      roleParams = Client $ defC {
        onCertificateRequest = const $ return p12
      }
    }

  let conf' = ApnsConf tlsParam gwHost (read gwPort) 5000000 undefined
      mkConn = evalSendM connectApns conf'
  pool <- liftIO $ mkPool mkConn 5
  let conf = conf' { acConnPool = pool}

  return conf
 where
  defP = defaultParamsClient
  Client defC = roleParams defP

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
  
  resps <- send conf msgs
  print resps
  return ()

