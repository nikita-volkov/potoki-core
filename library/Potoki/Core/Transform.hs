module Potoki.Core.Transform where

import Potoki.Core.Prelude
import qualified Potoki.Core.Fetch as A
import qualified Data.Attoparsec.ByteString as K
import qualified Data.Attoparsec.Text as L
import qualified Data.HashSet as C
import qualified Control.Concurrent.Chan.Unagi as B
import qualified Potoki.Core.IO as G
import qualified Data.ByteString.Builder as E
import qualified Data.ByteString.Lazy as F


newtype Transform input output =
  Transform (A.Fetch input -> IO (A.Fetch output))

instance Category Transform where
  id =
    Transform return
  (.) (Transform leftFetchIO) (Transform rightFetchIO) =
    Transform (leftFetchIO <=< rightFetchIO)

instance Profunctor Transform where
  dimap inputMapping outputMapping (Transform fetcherIO) =
    Transform (\inputFetch -> (fmap . fmap) outputMapping (fetcherIO (fmap inputMapping inputFetch)))

instance Strong Transform where
  first' (Transform io) =
    Transform (A.first io) 

{-|
The behaviour of this instance is that it stops on the first appearance of the opposite input.
I.e., if you focus on the left values, it'll apply the transform to all the left values up until
the first right value and will emit the result of the transform followed by the right value.
-}
instance Choice Transform where
  left' (Transform transform) =
    Transform $ \(A.Fetch fetchInputOrRight) -> do
      rightMaybeRef <- newIORef Nothing
      A.Fetch fetchOutput <-
        transform $ A.Fetch $ \stop emitInput ->
        fetchInputOrRight stop $ \case
          Left left -> emitInput left
          Right right -> do
            writeIORef rightMaybeRef (Just right)
            stop
      return $ A.Fetch $ \stop emitOutputOrRight -> do
        fetchOutput
          (do
            rightMaybe <- readIORef rightMaybeRef
            case rightMaybe of
              Just right -> do
                writeIORef rightMaybeRef Nothing
                emitOutputOrRight (Right right)
              Nothing -> stop)
          (\output -> emitOutputOrRight (Left output))

instance Arrow Transform where
  arr fn =
    Transform (pure . fmap fn)
  first =
    first'

instance ArrowChoice Transform where
  left =
    left'

{-|
Lift an Attoparsec ByteString parser.
-}
{-# INLINE parseBytes #-}
parseBytes :: K.Parser parsed -> Transform ByteString (Either Text parsed)
parseBytes parser =
  Transform (A.mapWithBytesParser parser)

{-|
Lift an Attoparsec Text parser.
-}
{-# INLINE parseText #-}
parseText :: L.Parser parsed -> Transform Text (Either Text parsed)
parseText parser =
  Transform (A.mapWithTextParser parser)

{-# INLINE take #-}
take :: Int -> Transform input input
take amount =
  Transform (A.take amount)

{-|
Same as 'arr'.
-}
{-# INLINE map #-}
map :: (input -> output) -> Transform input output
map mapping =
  arr mapping

{-# INLINE mapFilter #-}
mapFilter :: (input -> Maybe output) -> Transform input output
mapFilter mapping =
  Transform (pure . A.mapFilter mapping)

{-# INLINE just #-}
just :: Transform (Maybe input) input
just =
  Transform $ \(A.Fetch fetch) ->
  return $ A.Fetch $ \stop emit ->
  fix $ \loop ->
  fetch stop $ \case
    Just input -> emit input
    Nothing -> loop

{-# INLINE takeWhileIsJust #-}
takeWhileIsJust :: Transform (Maybe input) input
takeWhileIsJust =
  Transform (\(A.Fetch fetch) ->
    return (A.Fetch (\stop emit ->
      fetch stop (\case
        Just input -> emit input
        Nothing -> stop))))

{-# INLINE takeWhileIsLeft #-}
takeWhileIsLeft :: Transform (Either left right) left
takeWhileIsLeft =
  Transform (\(A.Fetch fetch) ->
    return (A.Fetch (\stop emit ->
      fetch stop (\case
        Left input -> emit input
        _ -> stop))))

{-# INLINE takeWhileIsRight #-}
takeWhileIsRight :: Transform (Either left right) right
takeWhileIsRight =
  Transform (\(A.Fetch fetch) ->
    return (A.Fetch (\stop emit ->
      fetch stop (\case
        Right input -> emit input
        _ -> stop))))

{-# INLINE takeWhile #-}
takeWhile :: (input -> Bool) -> Transform input input
takeWhile predicate =
  Transform $ \(A.Fetch fetch) ->
  return $ A.Fetch $ \stop emit ->
  fetch stop $ \input ->
  if predicate input
    then emit input
    else stop

{-# INLINABLE explode #-}
explode :: (input -> IO (A.Fetch output)) -> Transform input output
explode produce =
  Transform $ \ (A.Fetch fetch) -> do
    stateRef <- newIORef Nothing
    return $ A.Fetch $ \ stop emit -> fix $ \ loop -> do
      state <- readIORef stateRef
      case state of
        Just (A.Fetch fetch) ->
          fetch (writeIORef stateRef Nothing >> loop) emit
        Nothing ->
          fetch stop $ \ input -> do
            currentFetch <- produce input
            writeIORef stateRef (Just currentFetch)
            loop

{-# INLINE implode #-}
implode :: (A.Fetch input -> IO output) -> Transform input output
implode consume =
  Transform $ \(A.Fetch fetch) -> do
    stoppedRef <- newIORef False
    return $ A.Fetch $ \stopOutput emitOutput -> do
      stopped <- readIORef stoppedRef
      if stopped
        then stopOutput
        else do
          emittedRef <- newIORef False
          output <- consume $ A.Fetch $ \stopInput emitInput ->
            fetch
              (do
                writeIORef stoppedRef True
                stopInput)
              (\input -> do
                writeIORef emittedRef True
                emitInput input)
          stopped <- readIORef stoppedRef
          if stopped
            then do
              emitted <- readIORef emittedRef
              if emitted
                then emitOutput output
                else stopOutput
            else emitOutput output

{-# INLINE bufferize #-}
bufferize :: Transform element element
bufferize =
  Transform $ \(A.Fetch fetch) -> do
    (inChan, outChan) <- B.newChan
    forkIO $ fix $ \ loop ->
      fetch
        (B.writeChan inChan Nothing)
        (\ element -> do
          B.writeChan inChan $! Just $! element
          loop)
    return $ A.Fetch $ \stop emit -> B.readChan outChan >>= maybe stop emit

{-|
Execute the IO action.
-}
{-# INLINE executeIO #-}
executeIO :: Transform (IO a) a
executeIO =
  Transform $ \(A.Fetch fetch) ->
  return $ A.Fetch $ \stop emit ->
  fetch stop (\ io -> io >>= emit)

{-# INLINE failingIO #-}
failingIO :: (a -> IO (Either error ())) -> Transform a error
failingIO io =
  Transform $ \ (A.Fetch fetch) ->
  return $ A.Fetch $ \ stop emit ->
  fix $ \ loop ->
  fetch stop $ \ input ->
  io input >>= \ case
    Right () -> loop
    Left exception -> emit exception

{-# INLINE deleteFile #-}
deleteFile :: Transform FilePath IOException
deleteFile =
  failingIO G.deleteFile

{-# INLINE appendBytesToFile #-}
appendBytesToFile :: Transform (FilePath, ByteString) IOException
appendBytesToFile =
  failingIO (uncurry G.appendBytesToFile)

{-# INLINABLE scan #-}
scan :: (state -> input -> (output, state)) -> state -> Transform input output
scan progress start =
  Transform $ \ (A.Fetch fetch) -> do
    stateRef <- newIORef start
    return $ A.Fetch $ \ stop emit -> fetch stop $ \ input -> do
      !state <- readIORef stateRef
      case progress state input of
        (output, !newState) -> do
          writeIORef stateRef newState
          emit output

{-# INLINE distinct #-}
distinct :: (Eq element, Hashable element) => Transform element element
distinct =
  Transform $ \ (A.Fetch fetch) -> do
    stateRef <- newIORef mempty
    return $ A.Fetch $ \ stop emit -> fix $ \ loop -> fetch stop $ \ input -> do
      !set <- readIORef stateRef
      if C.member input set
        then loop
        else do
          writeIORef stateRef $! C.insert input set
          emit input

{-# INLINE builderChunks #-}
builderChunks :: Transform E.Builder ByteString
builderChunks =
  explode $ \ builder -> do
    chunkListRef <- newIORef (F.toChunks (E.toLazyByteString builder))
    return (A.list chunkListRef)
