module Potoki.Core.Fetch
(
  Fetch(..),
  duplicate,
  maybeRef,
  list,
  firstCachingSecond,
  bothFetchingFirst,
  rightHandlingLeft,
  rightCachingLeft,
  eitherFetchingRight,
  signaling,
  ioFetch,
)
where

import Potoki.Core.Prelude
import Potoki.Core.Types


deriving instance Functor Fetch

instance Applicative Fetch where
  pure x =
    Fetch (pure (Just x))
  (<*>) (Fetch leftIO) (Fetch rightIO) =
    Fetch ((<*>) <$> leftIO <*> rightIO)

instance Monad Fetch where
  return =
    pure
  (>>=) (Fetch leftIO) rightFetch =
    Fetch $ do
      leftFetching <- leftIO
      case leftFetching of
        Nothing -> return Nothing
        Just leftElement -> case rightFetch leftElement of
          Fetch rightIO -> rightIO

instance Alternative Fetch where
  empty =
    Fetch (pure Nothing)
  (<|>) (Fetch leftIO) (Fetch rightIO) =
    Fetch ((<|>) <$> leftIO <*> rightIO)

instance MonadPlus Fetch where
  mzero =
    empty
  mplus =
    (<|>)

{-# INLINABLE duplicate #-}
duplicate :: Fetch element -> IO (Fetch element, Fetch element)
duplicate (Fetch fetchIO) =
  do
    leftBuffer  <- newTQueueIO
    rightBuffer <- newTQueueIO
    notFetchingVar <- newTVarIO True
    notEndVar      <- newTVarIO True
    let
      newFetch ownBuffer mirrorBuffer =
        Fetch $ do
          fetch <- fetchIO
          join
            (atomically
               (mplus
                  (do
                     element <- readTQueue ownBuffer
                     return $ return (Just element)
                  )
                  (do
                     notEnd <- readTVar notEndVar
                     if notEnd
                     then do
                       notFetching <- readTVar notFetchingVar
                       guard notFetching
                       writeTVar notFetchingVar False
                       return $ 
                         case fetch of
                           Nothing      -> do
                             atomically
                               (do
                                  writeTVar notEndVar False
                                  writeTVar notFetchingVar True
                               )
                             return Nothing
                           Just !element -> do
                             atomically
                               (do
                                  writeTQueue mirrorBuffer element
                                  writeTVar notFetchingVar True
                               )
                             return (Just element)
                     else return $ return Nothing
                  )
               )
            ) 
      leftFetch =
        newFetch leftBuffer rightBuffer
      rightFetch =
        newFetch rightBuffer leftBuffer
     in return (leftFetch, rightFetch)

{-# INLINABLE maybeRef #-}
maybeRef :: IORef (Maybe a) -> Fetch a
maybeRef refElem =
  Fetch $ do
    elem <- readIORef refElem
    case elem of
      Nothing -> return Nothing
      Just e  -> do
        writeIORef refElem Nothing
        return $ Just e

{-# INLINABLE list #-}
list :: IORef [element] -> Fetch element
list unsentListRef =
  Fetch $ do
    refList <- readIORef unsentListRef
    case refList of
      (!head) : tail -> do
        writeIORef unsentListRef tail
        return $ Just head
      _              -> do
        writeIORef unsentListRef []
        return Nothing

{-# INLINABLE firstCachingSecond #-}
firstCachingSecond :: IORef b -> Fetch (a, b) -> Fetch a
firstCachingSecond cacheRef (Fetch bothFetchIO) =
  Fetch $ join $ do
    bothFetch <- bothFetchIO
    return $ case bothFetch of
      Nothing                -> return Nothing
      Just (!first, !second) -> do
        writeIORef cacheRef second
        return (Just first)

{-# INLINABLE bothFetchingFirst #-}
bothFetchingFirst :: IORef b -> Fetch a -> Fetch (a, b)
bothFetchingFirst cacheRef (Fetch firstFetchIO) =
  Fetch $ join $ do
     firstFetch <- firstFetchIO
     return $ case firstFetch of
       Nothing            -> return Nothing
       Just !firstFetched -> do
         secondCached <- readIORef cacheRef
         return (Just (firstFetched, secondCached))

{-# INLINABLE rightHandlingLeft #-}
rightHandlingLeft :: (left -> IO ()) -> Fetch (Either left right) -> Fetch right
rightHandlingLeft handle (Fetch eitherFetchIO) =
  Fetch $ join $ do
    eitherFetch <- eitherFetchIO
    return $ case eitherFetch of
      Nothing      -> return Nothing
      Just eitherJ -> case eitherJ of
        Right !rightInput -> return (Just rightInput)
        Left  !leftInput  -> handle leftInput $> Nothing

{-# INLINABLE rightCachingLeft #-}
rightCachingLeft :: IORef (Maybe left) -> Fetch (Either left right) -> Fetch right
rightCachingLeft cacheRef =
  rightHandlingLeft (writeIORef cacheRef . Just)

{-# INLINABLE eitherFetchingRight #-}
eitherFetchingRight :: IORef (Maybe left) -> Fetch right -> Fetch (Either left right)
eitherFetchingRight cacheRef (Fetch rightFetchIO) =
  Fetch $ join $ do
    rightFetch <- rightFetchIO
    return $ case rightFetch of
      Nothing -> return Nothing
      Just r  -> atomicModifyIORef' cacheRef $ \ case
        Nothing -> (Nothing, Just (Right r))
        Just l  -> (Nothing, Just (Left  l))

{-# INLINABLE signaling #-}
signaling :: IO () -> IO () -> Fetch a -> Fetch a
signaling signalEnd signalElement (Fetch aFetchIO) =
  Fetch $ join $ do
    aFetch <- aFetchIO
    return $ case aFetch of
      Nothing      -> signalEnd $> Nothing
      Just element -> signalElement >> return (Just element)

{-# INLINABLE ioFetch #-}
ioFetch :: IO (Fetch a) -> Fetch a
ioFetch fetchIO =
  Fetch $ do
    Fetch fetch <- fetchIO
    fetch
