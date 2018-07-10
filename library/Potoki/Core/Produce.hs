module Potoki.Core.Produce
(
  Produce(..),
  list,
  transform,
  vector,
  hashMapRows,
  fileBytes,
  fileBytesAtOffset,
  fileText,
  stdinBytes,
  directoryContents,
  finiteMVar,
  infiniteMVar,
  lazyByteString,
)
where

import Potoki.Core.Prelude
import Potoki.Core.Types
import qualified Potoki.Core.Fetch as A
import qualified Data.HashMap.Strict as B
import qualified Data.Vector as C
import qualified System.Directory as G
import qualified Acquire.Acquire as M
import qualified Data.ByteString.Lazy as D


deriving instance Functor Produce

instance Applicative Produce where
  pure x = Produce $ do
    refX <- liftIO (newIORef (Just x))
    return (A.maybeRef refX)
  (<*>) (Produce leftAcquire) (Produce rightAcquire) =
    Produce ((<*>) <$> leftAcquire <*> rightAcquire)

instance Alternative Produce where
  empty =
    Produce (pure empty)
  (<|>) (Produce leftAcquire) (Produce rightAcquire) =
    Produce ((<|>) <$> leftAcquire <*> rightAcquire)

instance Monad Produce where
  return = pure
  (>>=) (Produce (Acquire io1)) k2 =
    Produce $ Acquire $ do
      (A.Fetch fetch1, release1) <- io1
      release2Ref <- newIORef (return ())
      fetch3Var <- newIORef (return Nothing)
      let
        fetch2 input1 =
          case k2 input1 of
            Produce (Acquire io2) -> do
              join (readIORef release2Ref)
              (A.Fetch fetch2', release2') <- io2
              writeIORef release2Ref release2'
              return fetch2'
        release3 =
          join (readIORef release2Ref) >> release1
        fetch3 =  do
            res <- readIORef fetch3Var
            mayY <- res
            case mayY of
              Nothing -> do
                mayX <- fetch1
                case mayX of
                  Nothing -> return Nothing
                  Just x -> do
                    fetch2 x >>= writeIORef fetch3Var
                    fetch3
              Just y  -> return $ Just y
      return (A.Fetch fetch3, release3)

instance MonadIO Produce where
  liftIO io = Produce . liftIO $ do
    refX <- newIORef $ Just io
    let fetch = A.Fetch $ fetchIO refX
          where
            fetchIO ref = do
              elemVal <- readIORef ref
              for elemVal $ \getElement -> do
                  writeIORef ref Nothing
                  getElement
    return fetch

{-# INLINABLE list #-}
list :: [input] -> Produce input
list inputList =
  Produce $ liftIO (A.list <$> newIORef inputList)

{-# INLINE transform #-}
transform :: Transform input output -> Produce input -> Produce output
transform (Transform transformAcquire) (Produce produceAcquire) =
  Produce $ do
    fetch <- produceAcquire
    transformAcquire fetch

{-# INLINE vector #-}
vector :: Vector input -> Produce input
vector vectorVal =
  Produce $ M.Acquire $ do
    indexRef <- newIORef 0
    let
      fetch =
        A.Fetch $ do
          indexVal <- readIORef indexRef
          writeIORef indexRef $! succ indexVal
          return $ (C.!?) vectorVal indexVal
      in return (fetch, return ())

{-# INLINE hashMapRows #-}
hashMapRows :: HashMap a b -> Produce (a, b)
hashMapRows =
  list . B.toList

{-|
Read from a file by path.

* Exception-free
* Automatic resource management
-}
{-# INLINABLE fileBytes #-}
fileBytes :: FilePath -> Produce (Either IOException ByteString)
fileBytes path =
  accessingHandle (openBinaryFile path ReadMode) A.handleBytes

{-|
Read from a file by path.

* Exception-free
* Automatic resource management
-}
{-# INLINABLE fileBytesAtOffset #-}
fileBytesAtOffset :: FilePath -> Int -> Produce (Either IOException ByteString)
fileBytesAtOffset path offset =
  accessingHandle acquire A.handleBytes
  where
    acquire =
      do
        handleVal <- openBinaryFile path ReadMode
        hSeek handleVal AbsoluteSeek (fromIntegral offset)
        return handleVal

{-# INLINABLE accessingHandle #-}
accessingHandle :: IO Handle -> (Handle -> A.Fetch (Either IOException a)) -> Produce (Either IOException a)
accessingHandle acquireHandle fetch =
  Produce $ M.Acquire (catchIOError normal failing)
  where
    normal =
      do
        handleVal <- acquireHandle
        return (fetch handleVal, catchIOError (hClose handleVal) (const (return ())))
    failing exception =
      return (pure (Left exception), return ())

{-# INLINABLE stdinBytes #-}
stdinBytes :: Produce (Either IOException ByteString)
stdinBytes =
  Produce $ M.Acquire (return (A.handleBytes stdin, return ()))

{-|
Sorted subpaths of the directory.
-}
{-# INLINABLE directoryContents #-}
directoryContents :: FilePath -> Produce (Either IOException FilePath)
directoryContents path =
  Produce $ M.Acquire (catchIOError success failure)
  where
    success =
      do
        subPaths <- G.listDirectory path
        ref <- newIORef (map (Right . mappend path . (:) '/') (sort subPaths))
        return (A.list ref, return ())
    failure exception =
      return (pure (Left exception), return ())

{-|
Read from a file by path.

* Exception-free
* Automatic resource management
-}
{-# INLINABLE fileText #-}
fileText :: FilePath -> Produce (Either IOException Text)
fileText path =
  Produce $ M.Acquire (catchIOError success failure)
  where
    success =
      do
        handleVal <- openFile path ReadMode
        return (A.handleText handleVal, catchIOError (hClose handleVal) (const (return ())))
    failure exception =
      return (pure (Left exception), return ())

{-|
Read from MVar.
Nothing gets interpreted as the end of input.
-}
{-# INLINE finiteMVar #-}
finiteMVar :: MVar (Maybe element) -> Produce element
finiteMVar var =
  Produce $ M.Acquire (return (A.finiteMVar var, return ()))

{-|
Read from MVar.
Never stops.
-}
{-# INLINE infiniteMVar #-}
infiniteMVar :: MVar element -> Produce element
infiniteMVar var =
  Produce $ M.Acquire (return (A.infiniteMVar var, return ()))

{-# INLINE lazyByteString #-}
lazyByteString :: D.ByteString -> Produce ByteString
lazyByteString lbs =
  Produce $ M.Acquire $ do
    ref <- newIORef lbs
    return (A.lazyByteStringRef ref, return ())
