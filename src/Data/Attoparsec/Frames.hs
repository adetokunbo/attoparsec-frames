{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_HADDOCK prune not-home #-}

module Data.Attoparsec.Frames (
  -- * Frames
  mkFrames,
  Frames,
  receiveFrame,
  receiveFrames,
  chunkSize,
  setChunkSize,
  setOnBadParse,
  setOnClosed,
  BrokenFrame (..),
  NoMoreInput (..),

  -- * Frame size
  FrameSize (..),
  parseSizedFrame,
) where

import Control.Exception (Exception, throwIO)
import Control.Monad.IO.Class (MonadIO, liftIO)
import qualified Data.Attoparsec.ByteString as A
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32)


class FrameSize a where
  frameSize :: a -> Word32


parseSizedFrame :: FrameSize h => A.Parser h -> (Word32 -> A.Parser b) -> A.Parser (h, b)
parseSizedFrame parseHead mkParseBody = do
  h <- parseHead
  body <- mkParseBody $ frameSize h
  pure (h, body)


data Frames m a = Frames
  { framerChunkSize :: !Word32
  , framerOnBadParse :: !(Text -> m ())
  , framerFetchBytes :: !(Word32 -> m ByteString)
  , framerOnFrame :: !(a -> m ())
  , framerParser :: !(A.Parser a)
  , framerOnClosed :: !(m ())
  }


mkFrames ::
  MonadIO m =>
  A.Parser a ->
  (a -> m ()) ->
  (Word32 -> m ByteString) ->
  Frames m a
mkFrames parser onFrame fetchBytes =
  Frames
    { framerChunkSize = 2048
    , framerOnBadParse = \_err -> pure ()
    , framerFetchBytes = fetchBytes
    , framerOnFrame = onFrame
    , framerParser = parser
    , framerOnClosed = liftIO $ throwIO NoMoreInput
    }


receiveFrames ::
  MonadIO m =>
  Frames m a ->
  m ()
receiveFrames f =
  let Frames
        { framerChunkSize = fetchSize
        , framerOnBadParse = onErr
        , framerFetchBytes = fetchBytes
        , framerOnFrame = onFrame
        , framerParser = parser
        , framerOnClosed = onClosed
        } = f
   in receiveFrames' fetchSize parser fetchBytes onFrame onErr onClosed


chunkSize :: Frames m a -> Word32
chunkSize = framerChunkSize


setChunkSize :: Word32 -> Frames m a -> Frames m a
setChunkSize size f = f {framerChunkSize = size}


setOnBadParse :: (Text -> m ()) -> Frames m a -> Frames m a
setOnBadParse onErr f = f {framerOnBadParse = onErr}


setOnClosed :: (m ()) -> Frames m a -> Frames m a
setOnClosed onClose f = f {framerOnClosed = onClose}


receiveFrames' ::
  MonadIO m =>
  Word32 ->
  A.Parser a ->
  (Word32 -> m ByteString) ->
  (a -> m ()) ->
  (Text -> m ()) ->
  m () ->
  m ()
receiveFrames' fetchSize parser fetchBytes handleFrame onErr onClosed = do
  let loop x = do
        (next, closed) <- receiveFrame' x fetchSize parser fetchBytes handleFrame onErr onClosed
        if not closed then loop next else pure ()
  loop Nothing


receiveFrame ::
  MonadIO m =>
  Maybe ByteString ->
  Frames m a ->
  m ((Maybe ByteString), Bool)
receiveFrame restMb f =
  let Frames
        { framerChunkSize = fetchSize
        , framerOnBadParse = onErr
        , framerFetchBytes = fetchBytes
        , framerOnFrame = onFrame
        , framerParser = parser
        , framerOnClosed = onClose
        } = f
   in receiveFrame' restMb fetchSize parser fetchBytes onFrame onErr onClose


receiveFrame' ::
  MonadIO m =>
  Maybe ByteString ->
  Word32 ->
  A.Parser a ->
  (Word32 -> m ByteString) ->
  (a -> m ()) ->
  (Text -> m ()) ->
  m () ->
  m ((Maybe ByteString), Bool)
receiveFrame' restMb fetchSize parser fetchBytes handleFrame onErr onClose = do
  let pullChunk = fetchBytes fetchSize
      initial = fromMaybe BS.empty restMb
      onParse (A.Fail _ ctxs reason) = do
        let errMessage = parsingFailed ctxs reason
        if reason == closedReason
          then -- TODO: determine a way of detecting this condition that is
          -- independent of the error text
          do
            onClose
            pure (Nothing, True)
          else do
            onErr errMessage
            liftIO $ throwIO $ BrokenFrame reason
      onParse (A.Done i r) = do
        handleFrame r
        pure ((if BS.null i then Nothing else Just i), False)
      onParse (A.Partial continue) = pullChunk >>= onParse . continue
  A.parseWith pullChunk parser initial >>= onParse


parsingFailed :: [String] -> String -> Text
parsingFailed context reason =
  let contexts = Text.intercalate "-" (Text.pack <$> context)
      cause = if null reason then Text.empty else ":" <> Text.pack reason
   in "bad parse:" <> contexts <> cause


data BrokenFrame = BrokenFrame String
  deriving (Eq, Show)


instance Exception BrokenFrame


data NoMoreInput = NoMoreInput
  deriving (Eq, Show)


instance Exception NoMoreInput


closedReason :: String
closedReason = "not enough input"
