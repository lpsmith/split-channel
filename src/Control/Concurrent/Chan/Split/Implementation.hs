{-# LANGUAGE DeriveDataTypeable #-}

------------------------------------------------------------------------------
-- |
-- Module      :  Control.Concurrent.Chan.Split.Implementation
-- Copyright   :  (c) 2012 Leon P Smith
-- License     :  MIT
--
-- Maintainer  :  leon@melding-monads.com
--
------------------------------------------------------------------------------

module Control.Concurrent.Chan.Split.Implementation where

import Control.Applicative
import Control.Concurrent.MVar
import Control.Exception(mask_, onException)
import Data.IORef
import Data.Typeable(Typeable)
import System.IO.Unsafe(unsafeInterleaveIO)

type List a = MVar (Item a)

data Item a = Item a {-# UNPACK #-} !(List a)

-- | @SendPorts@ represent one end of the channel.   There is only one
--   @SendPort@ per channel,  though it can be used from multiple threads.
--   Messages can be sent to the channel using 'send'.

newtype SendPort a = SendPort (MVar (List a)) deriving (Eq, Typeable)


-- | @ReceivePorts@ represent the other end of a channel.   A channel
--   can have many @ReceivePorts@,  which all receive the same messages in
--   a publish/subscribe like manner.  A single @ReceivePort@ can be used
--   from multiple threads,  where every message will be delivered to a
--   single thread in a push/pull like manner.  Use 'receive' to fetch
--   messages from the channel.

data ReceivePort a = ReceivePort
    { rp_ref  :: {-# UNPACK #-} !(IORef (List a))
    , rp_lock :: {-# UNPACK #-} !(MVar ())
    } deriving (Eq, Typeable)


-- | Creates a new channel and a  @(SendPort, ReceivePort)@ pair representing
--   the two sides of the channel.

new :: IO (SendPort a, ReceivePort a)
new = do
   hole <- newEmptyMVar
   send <- SendPort <$> newMVar hole
   recv <- ReceivePort <$> newIORef hole <*> newMVar ()
   return (send, recv)


-- | Produces a new channel that initially has zero @ReceivePorts@.
--   Any messages written to this channel before a reader is @'listen'ing@
--   will be eligible for garbage collection.   Note that one can
--   one can implement 'newSendPort' in terms of 'new' by throwing away the
--   'ReceivePort' and letting it be garbage collected,   and that one can
--   implement 'new' in terms of 'newSendPort' and 'listen'.

newSendPort :: IO (SendPort a)
newSendPort = SendPort `fmap` (newMVar =<< newEmptyMVar)


-- | Create a new @ReceivePort@ attached the same channel as a given
--   @SendPort@.  This @ReceivePort@ starts out empty, and remains so
--   until more messages are written to the @SendPort@.

listen :: SendPort a  -> IO (ReceivePort a)
listen (SendPort a) = ReceivePort <$> (newIORef =<< readMVar a) <*> newMVar ()


-- | Create a new @ReceivePort@ attached to the same channel as another
--   @ReceivePort@.  These two ports will receive the same messages.
--   Any messages in the channel that have not been consumed by the
--   existing port will also appear in the new port.

duplicate :: ReceivePort a  -> IO (ReceivePort a)
duplicate   (ReceivePort ref _) = do
    rp_ref  <- newIORef =<< readIORef ref
    rp_lock <- newMVar ()
    return $! ReceivePort rp_ref rp_lock

-- | Fetch a message from a channel.  If no message is available,  it blocks
--   until one is.  Can be used in conjunction with @System.Timeout@.

receive :: ReceivePort a -> IO a
receive (ReceivePort ref lock) =
    withLock lock $ do
      read_end <- readIORef ref
      (Item val new_read_end) <- readMVar read_end
      writeIORef ref new_read_end
      return val

-- | Send a message to a channel.   This is asynchronous and does not block.

send :: SendPort a -> a -> IO ()
send (SendPort s) a = do
    new_hole <- newEmptyMVar
    mask_ $ do
      old_hole <- takeMVar s
      putMVar old_hole (Item a new_hole)
      putMVar s new_hole

-- | A right fold over a receiver,  a generalization of @getChanContents@
--   where @getChanContents = fold (:)@. Note that the type of 'fold'
--   implies that the folding function needs to be sufficiently non-strict,
--   otherwise the result cannot be productive.

fold :: (a -> b -> b) -> ReceivePort a -> IO b
fold f (ReceivePort ref _) = readIORef ref >>= foldList f

-- | Traverse a 'List' directly.  Avoids the outer 'MVar' overhead of calling
-- 'receive' over and over.
foldList :: (a -> b -> b) -> List a -> IO b
foldList f list =
    unsafeInterleaveIO $ do
        Item a list' <- readMVar list
        b <- foldList f list'
        return (f a b)

-- | Atomically send many messages at once.   Note that this function
--   forces the spine of the list beforehand to minimize the critical section,
--   which also helps prevent exceptions at inopportune times.  Trying to send
--   an infinite list will never send anything,  though it will allocate and
--   retain a lot of memory trying to do so.

sendMany :: SendPort a -> [a] -> IO ()
sendMany _ [] = return ()
sendMany s (a:as) = do
    new_hole <- newEmptyMVar
    loop s (Item a new_hole) new_hole as
  where
    loop s msgs hole (a:as) = do
       new_hole <- newEmptyMVar
       putMVar hole (Item a new_hole)
       loop s msgs new_hole as
    loop (SendPort s) msgs new_hole [] = mask_ $ do
       hole <- takeMVar s
       putMVar hole msgs
       putMVar s new_hole

-- | This function splits an existing channel in two;  associating
--   a new receive port with the old send port,  and a new send
--   port with the existing receive ports.   The new receive port
--   starts out empty,  while the existing receive ports retain
--   any unprocessed messages.
--
--   <<split.png>>

split :: SendPort a -> IO (ReceivePort a, SendPort a)
split (SendPort s) = do
    new_hole <- newEmptyMVar
    old_hole <- swapMVar s new_hole
    rp <- ReceivePort <$> newIORef new_hole <*> newMVar ()
    sp <- SendPort `fmap` newMVar old_hole
    return (rp, sp)


{-# INLINE withLock #-}
withLock :: MVar () -> IO b -> IO b
withLock m io =
  mask_ $ do
    _ <- takeMVar m
    b <- io `onException` putMVar m ()
    putMVar m ()
    return b
