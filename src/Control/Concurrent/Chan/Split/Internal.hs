{-# OPTIONS_HADDOCK hide #-}
------------------------------------------------------------------------------
-- |
-- Module      :  Control.Concurrent.Chan.Split.Internal
-- Copyright   :  (c) 2012 Leon P Smith
-- License     :  MIT
--
-- Maintainer  :  leon@melding-monads.com
--
-- The point of this module is that there are many potentially useful
-- operations on split channels not supported by the existing interface.
-- This includes atomic sequences of operations,  and playing tricks
-- with ports.  I've included one such examples in this module;  if you
-- come up with any compelling use cases for these or other operations,
-- let me know and I'll consider including them in the public API.
--
-- Note that the usual caveat that this module does not follow Cabal's
-- Package Versioning policy applies.   This can change at any time,
-- potentially even breaking your code without causing a compile-time
-- error.
--
------------------------------------------------------------------------------

module Control.Concurrent.Chan.Split.Internal
     ( SendPort(..)
     , ReceivePort(..)
     , List
     , Item(..)
     , sendMany
     , sendAndResetChannel
     ) where

import Control.Concurrent.MVar
import Control.Exception(mask_)
import Control.Concurrent.Chan.Split.Implementation

-- | Atomically send many messages at once.   Note that this function
--   minimizes the critical section and forces the spine of the list, which
--   helps prevent exceptions at inopportune times.  Might be useful in
--   improving throughput of SendPorts with high contention,  or for ensuring
--   that two messages appear next to each other.

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

-- | Atomically sends a message on a channel,  and then associates a new
--   channel with the @SendPort@.   This prevents the existing @ReceivePorts@
--   on the old channel from receiving further messages,  and creates a new
--   ReceivePort for the new channel.  A possible use case is to transparently
--   replace the backend of a service without effecting the clients of that
--   service.
--
--   This is probably not a good idea, however.   It's probably better to
--   put the SendPort in an MVar instead.  This introduces an extra layer
--   of indirection,  but also allows you to be selective about which
--   senders see the effect,  by providing either an @MVar@ to the @SendPort@
--   or providing the @SendPort@ directly.
--
--   For example,  the service might consist of multiple threads,  some
--   of which may send messages on the same channel as the clients.  It
--   would probably be a bug to switch the channel that those internal
--   threads are using:  so the clients would use an
--   @MVar (SendPort RequestOrInternalMessage)@ whereas the internal
--   threads would have direct access to the same @SendPort@.

sendAndResetChannel :: SendPort a -> a -> IO (ReceivePort a)
sendAndResetChannel (SendPort s) a = do
   new_hole  <- newEmptyMVar
   new_hole' <- newEmptyMVar
   mask_ $ do
     old_hole <- takeMVar s
     putMVar old_hole (Item a new_hole)
     putMVar s new_hole'
   ReceivePort `fmap` newMVar new_hole'
