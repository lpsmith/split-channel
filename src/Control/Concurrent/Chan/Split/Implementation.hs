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

import Control.Concurrent.MVar
import Control.Exception(mask_, onException)
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

newtype ReceivePort a = ReceivePort (MVar (List a)) deriving (Eq, Typeable)


-- | Creates a new channel and a  @(SendPort, ReceivePort)@ pair representing
--   the two sides of the channel.

new :: IO (SendPort a, ReceivePort a)
new = do
   hole <- newEmptyMVar
   send <- SendPort `fmap` newMVar hole
   recv <- ReceivePort `fmap` newMVar hole
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
listen   (SendPort a) =  ReceivePort `fmap` withMVar a newMVar


-- | Create a new @ReceivePort@ attached to the same channel as another
--   @ReceivePort@.  These two ports will receive the same messages.
--   Any messages in the channel that have not been consumed by the
--   existing port will also appear in the new port.
--
--   Warning: this will block if another thread is blocked on 'receive' with
--   the same 'ReceivePort'.

duplicate :: ReceivePort a  -> IO (ReceivePort a)
duplicate   (ReceivePort a) =  ReceivePort `fmap` withMVar a newMVar


-- | Fetch a message from a channel.  If no message is available,  it blocks
--   until one is.  Can be used in conjunction with @System.Timeout@.

receive :: ReceivePort a -> IO a
receive (ReceivePort r) =
    compat_modifyMVarMasked r $ \read_end -> do
      (Item val new_read_end) <- readMVar read_end
      return (new_read_end, val)

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
--
--   Normally, this will return immediately; forcing the returned value will
--   wait for the next item using lazy IO.  However, 'fold' has the same caveat
--   as 'duplicate': it will block if other threads are blocked on 'receive'
--   with the same 'ReceivePort'.

fold :: (a -> b -> b) -> ReceivePort a -> IO b
fold f (ReceivePort r) = readMVar r >>= foldList f
    -- To avoid the blocking caveat, we could put unsafeInterleaveIO on
    -- the outside, but it would break determinism: items taken from the
    -- 'ReceivePort' before forcing the return value would be missed by
    -- the fold.

-- | Traverse a 'List' directly.  Avoids the outer 'MVar' overhead of calling
-- 'receive' over and over.
foldList :: (a -> b -> b) -> List a -> IO b
foldList f list =
    unsafeInterleaveIO $ do
        Item a list' <- readMVar list
        b <- foldList f list'
        return (f a b)

-- | 'unsafeFold' should usually be called only on readers that are not
--   subsequently used in other channel operations.  Otherwise it may be
--   possible that the (non-)evaluation of pure values can cause race
--   conditions inside IO computations.  The safer 'fold' uses 'duplicate'
--   to avoid this issue.

unsafeFold :: (a -> b -> b) -> ReceivePort a -> IO b
unsafeFold f = loop
   where
     loop source = unsafeInterleaveIO $ do
       a <- receive source
       b <- loop source
       return (f a b)

   -- Do not implement 'unsafeFold' with 'foldList', or it will change the
   -- semantics.  Currently, 'unsafeFold' updates the 'ReceivePort' as it goes.


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
    rp <- ReceivePort `fmap` newMVar new_hole
    sp <- SendPort `fmap` newMVar old_hole
    return (rp, sp)


------------------------------------------------------------------------
-- Compatibility; definitions copied from the base package

-- base 4.6: 'Control.Concurrent.MVar.modifyMVarMasked'
compat_modifyMVarMasked :: MVar a -> (a -> IO (a,b)) -> IO b
compat_modifyMVarMasked m io =
  mask_ $ do
    a      <- takeMVar m
    (a',b) <- io a `onException` putMVar m a
    putMVar m a'
    return b
