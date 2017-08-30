module Potok.Core.Consume where

import Potok.Prelude
import qualified Potok.Core.Fetch as A
import qualified Control.Concurrent.Async as B
import qualified Data.ByteString as C


{-|
The primary motivation for providing the @output@ type is the encoding of failures.
-}
newtype Consume input output =
  {-|
  An action, which uses a provided fetcher to perform IO,
  while managing the resources behind the scenes.
  -}
  Consume (A.Fetch input -> IO output)


{-# INLINE head #-}
head :: Consume input (Maybe input)
head =
  Consume (\(A.Fetch send) -> send (pure Nothing) (pure . Just))

{-# INLINABLE list #-}
list :: Consume input [input]
list =
  Consume $ \(A.Fetch send) -> build send id
  where
    build send acc =
      send (pure (acc [])) (\element -> build send ((:) element . acc))

{-|
A faster alternative to "list",
which however produces the list in the reverse order.
-}
{-# INLINABLE reverseList #-}
reverseList :: Consume input [input]
reverseList =
  Consume $ \(A.Fetch send) -> build send []
  where
    build send acc =
      send (pure acc) (\element -> build send (element : acc))

{-|
Overwrite a file.

* Exception-free
* Automatic resource management
-}
writeBytesToFile :: FilePath -> Consume ByteString (Maybe IOException)
writeBytesToFile path =
  Consume $ \(A.Fetch send) -> do
    exceptionOrUnit <- try $ withFile path WriteMode $ \handle -> write handle send
    case exceptionOrUnit of
      Left exception -> return (Just exception)
      Right () -> return Nothing
  where
    write handle send =
      fix (\loop -> send (return ()) (\bytes -> C.hPut handle bytes >> loop))