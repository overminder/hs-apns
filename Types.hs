{-# LANGUAGE RecordWildCards, DeriveDataTypeable #-}

module Types where

import Control.Exception
import Control.Applicative
import qualified Data.Attoparsec as A
import qualified Data.Attoparsec.Binary as A
import qualified Data.ByteString as B
import qualified Data.ByteString.Base16 as B16
import qualified Data.Map as M
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Serialize as S
import Data.Data
import Data.Time
import Debug.Trace
import Text.Printf
import Data.Time.Clock.POSIX
import Pipes

trace2 :: String -> a -> a
trace2 = const id

data Message
  = Message {
    msgDeviceToken :: !T.Text,
    msgIdent :: !Int,
    msgPayload :: !T.Text,
    msgExpiryDate :: !UTCTime,
    msgPriority :: !Priority
  }
  deriving (Show, Eq, Ord)

data Priority
  = Immediately
  | Conservely
  deriving (Show, Eq, Ord)

data Feedback
  = Feedback {
    fbTimestamp :: UTCTime,
    fbDeviceToken :: T.Text
  }

instance Enum Priority where
  fromEnum Immediately = 10
  fromEnum Conservely  = 5
  toEnum 10 = Immediately
  toEnum 5  = Conservely

data Response
  = Response {
    resStatus :: !ResponseStatus,
    resIdent :: !Int
  }
  deriving (Show, Eq, Ord)

data ResponseStatus
  = NoError
  | ProcessingError
  | MissingDeviceToken
  | MissingTopic
  | MissingPayload
  | InvalidTokenSize
  | InvalidTopicSize
  | InvalidPayloadSize
  | InvalidToken
  | Shutdown
  | Unknown
  deriving (Show, Eq, Ord)

data ApnsException
  = ResponseParseError String
  deriving (Eq, Show, Ord, Data, Typeable)

instance Exception ApnsException

resStatusMapping
  = [ (0, NoError)
    , (1, ProcessingError)
    , (2, MissingDeviceToken)
    , (3, MissingTopic)
    , (4, MissingPayload)
    , (5, InvalidTokenSize)
    , (6, InvalidTopicSize)
    , (7, InvalidPayloadSize)
    , (8, InvalidToken)
    , (10, Shutdown)
    , (255, Unknown)
    ]

enumToStatusMap = M.fromList resStatusMapping
statusToEnumMap = M.fromList (map xTup resStatusMapping)
 where
  xTup (a, b) = (b, a)

instance Enum ResponseStatus where
  fromEnum x = statusToEnumMap M.! x
  toEnum x = enumToStatusMap M.! x

fromMessage :: Monad m => Message -> Producer B.ByteString m ()
fromMessage msg = yield (S.runPut $ putMessage msg)

putMessage (Message {..}) = do
  S.putWord8 2
  let
    frame = S.runPut putFrame
    len = fromIntegral . B.length $ frame
  S.putWord32be (trace2 ("frameSiz = " ++ show len) len)
  S.putByteString frame
 where
  putFrame = do
    putItem 1 (fst . B16.decode . T.encodeUtf8 $ msgDeviceToken)
    putItem 2 (T.encodeUtf8 msgPayload)
    putItem 3 (S.runPut . S.putWord32be . fromIntegral $ msgIdent)
    putItem 4 (S.runPut . S.putWord32be . round .
               utcTimeToPOSIXSeconds $ msgExpiryDate)
    putItem 5 (B.singleton . fromIntegral . fromEnum $ msgPriority)
  putItem itemId itemData = do
    S.putWord8 itemId
    S.putWord16be (fromIntegral . B.length $ itemData)
    S.putByteString itemData

parseMessage :: A.Parser Message
parseMessage = do
  A.word8 2
  frameLen <- A.anyWord32be
  trace2 (printf "frameLen: %d" frameLen) $ return ()
  frameBs <- A.take $ fromIntegral frameLen
  let A.Done leftOver msg = A.parse parseFrame frameBs
  if B.null leftOver
    then return msg
    else error $ "parseMessage: leftover: " ++ show leftOver
 where
  parseFrame = do
    (1, 32) <- parseFrameHeader
    tok <- A.take 32

    (2, payloadLen) <- parseFrameHeader
    pl <- A.take $ fromIntegral payloadLen

    (3, 4) <- parseFrameHeader
    ident <- A.anyWord32be

    (4, 4) <- parseFrameHeader
    epoch <- A.anyWord32be

    (5, 1) <- parseFrameHeader
    prior <- A.anyWord8

    return $ Message {
      msgDeviceToken = T.decodeUtf8 $ B16.encode tok,
      msgIdent = fromIntegral ident,
      msgPayload = T.decodeUtf8 pl,
      msgExpiryDate = posixSecondsToUTCTime $ fromIntegral epoch,
      msgPriority = toEnum $ fromIntegral prior
    }

  parseFrameHeader = (,) <$> A.anyWord8 <*> A.anyWord16be

fromResponse :: Monad m => Response -> Producer B.ByteString m ()
fromResponse resp = undefined

parseResponse :: A.Parser Response
parseResponse
  = A.word8 8 *> (Response <$> (toEnum . fromIntegral <$> A.anyWord8)
                           <*> (fromIntegral <$> A.anyWord32be))

parseFeedback :: A.Parser Feedback
parseFeedback
  = Feedback <$> (posixSecondsToUTCTime . fromIntegral <$> A.anyWord32be)
             <*> (T.decodeUtf8 . B16.encode <$> (A.word16be 32 *> A.take 32))

