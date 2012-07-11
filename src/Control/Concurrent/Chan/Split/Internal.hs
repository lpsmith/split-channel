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
-- with ports.  I've included two such examples in this module;  if you
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
     , split
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

-- | This function associates a brand new channel with a existing send
--   port,  returning a receive port associated with the new channel 
--   and a new send port associated with the old channel.
-- 
--   A possible use case is to transparently replace the backend of a service
--   without affecting the clients of that service.  For example, we might 
--   use it along the following lines:
--
-- @
--       swapService :: SendPort Request -> IO ()
--       swapService s = do
--           (r', s') <- split s
--           send s' ShutdownRequest
--           forkNewService r'
-- @
--
--   However, I'm not sure this is a good justification for the existence
--   of the 'split' operator.  It is probably better to put the @SendPort@
--   in an @MVar@ instead of using 'split'.  This introduces an extra layer
--   of indirection, but also allows you to be selective about which senders
--   observe the effect.
--
--   For example,  the service might consist of multiple threads,  some
--   of which may send messages on the same channel as the clients.  It
--   would probably be a bug to change the channel that those internal
--   threads are using: so the clients would use an
--   @MVar (SendPort RequestOrInternalMessage)@ whereas the internal
--   threads would use the @SendPort RequestOrInternalMessage@ directly,
--   without going through the MVar.

split :: SendPort a -> IO (ReceivePort a, SendPort a)
split (SendPort s) = do
    new_hole <- newEmptyMVar
    old_hole <- swapMVar s new_hole
    rp <- ReceivePort `fmap` newMVar new_hole
    sp <- SendPort `fmap` newMVar old_hole
    return (rp, sp)
