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
import Control.Exception(mask_)
import System.IO.Unsafe(unsafeInterleaveIO)

type List a = MVar (Item a)

data Item a = Item a !(List a)

-- | @SendPorts@ represent one end of the channel.   There is only one
--   @SendPort@ per channel,  though it can be used from multiple threads.
--   Messages can be sent to the channel using 'send'.

newtype SendPort a = SendPort (MVar (List a))


-- | @ReceivePorts@ represent the other end of a channel.   A channel
--   can have many @ReceivePorts@,  which all receive the same messages in
--   a publish/subscribe like manner.  A single @ReceivePort@ can be used
--   from multiple threads,  where every message will be delivered to a
--   single thread in a push/pull like manner.  Use 'receive' to fetch
--   messages from the channel.

newtype ReceivePort a = ReceivePort (MVar (List a))


-- | Creates a new channel and a  @(SendPort, ReceivePort)@ pair representing
--   the two sides of the channel.

new :: IO (SendPort a, ReceivePort a)
new = do
   hole <- newEmptyMVar
   send <- SendPort `fmap` newMVar hole
   recv <- ReceivePort `fmap` newMVar hole
   return (send, recv)


-- | Produces a new channel that initially has zero @ReceivePorts@.
--   Any elements written to this channel before a reader is @'listen'ing@
--   will be eligible for garbage collection.

newSendPort :: IO (SendPort a)
newSendPort = SendPort `fmap` (newMVar =<< newEmptyMVar)


-- | Create a new @ReceivePort@ attached the same channel as a given
--   @SendPort@.  This @ReceivePort@ starts out empty, and remains so
--   until more elements are written to the @SendPort@.

listen :: SendPort a  -> IO (ReceivePort a)
listen   (SendPort a) =  ReceivePort `fmap` withMVar a newMVar


-- | Create a new @ReceivePort@ attached to the same channel as another
--   @ReceivePort@.  These two ports will receive the same messages.
--   Any messages in the channel that have not been consumed by the
--   existing port will also appear in the new port.

duplicate :: ReceivePort a  -> IO (ReceivePort a)
duplicate   (ReceivePort a) =  ReceivePort `fmap` withMVar a newMVar


-- | Fetch an element from a channel.  If no element is available,  it blocks
--   until one is.  Can be used in conjunction with @System.Timeout@.

receive :: ReceivePort a -> IO a
receive (ReceivePort r) = do
    modifyMVar r $ \read_end -> do
      (Item val new_read_end) <- readMVar read_end
      return (new_read_end, val)


-- | Send an element to a channel.   This is asynchronous and does not block.

send :: SendPort a -> a -> IO ()
send (SendPort s) a = do
    new_hole <- newEmptyMVar
    mask_ $ do
      old_hole <- takeMVar s
      putMVar old_hole (Item a new_hole)
      putMVar s new_hole

-- | A right fold over a receiver,  a generalization of @getChanContents@
--   where @getChanContents = fold (:)@. Note that the type of 'fold'
--   implies that the folding function needs to be sufficienctly non-strict,
--   otherwise the result cannot be productive.

fold :: (a -> b -> b) -> ReceivePort a -> IO b
fold f recv = unsafeFold f =<< duplicate recv


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
