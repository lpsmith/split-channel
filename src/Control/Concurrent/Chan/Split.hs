------------------------------------------------------------------------------
-- |
-- Module      :  Control.Concurrent.Chan.Split
-- Copyright   :  (c) 2012 Leon P Smith
-- License     :  MIT
--
-- Maintainer  :  leon@melding-monads.com
--
-- This package provides an unbounded, imperative queue that is supposed to
-- be thread safe and asynchronous exception safe.  It is essentially the
-- same communication abstraction as 'Control.Concurrent.Chan.Chan',  except
-- that each channel is split into separate sending and receiving ends,
-- called 'SendPort' and 'ReceivePort' respectively.  This has at least two
-- advantages:
--
-- 1. Program behavior can be more finely constrained via the type system.
--
-- 2. Channels can have zero @ReceivePorts@ associated with them.  Messages
--    written to such a channel disappear into the aether and can be
--    garbage collected.  Note that  @ReceivePorts@ can be subsequently
--    attached to such a channel via 'listen'.
--
-- A channel can have multiple @ReceivePorts@.  This results in a publish-
-- subscribe pattern of communication:  every element will be delivered to
-- every port.   Alternatively,  multiple threads can read from a single
-- port.  This results in a push-pull pattern of communication, similar to
-- ZeroMQ:  every element will be delivered to exactly one thread.   Of
-- course both can be used together to form hybrid patterns of
-- communication.
--
-- A channel can only have one @SendPort@.   However multiple threads can
-- can safely write to a single port,  allowing effects similar to  multiple
-- @SendPorts@.
--
-- Some of the tradeoffs of @split-channel@ compared to Cloud Haskell's
-- @Remote.Channel@ are:
--
-- 1.  @split-channel@ is restricted to in-process communications only.
--
-- 2.  @split-channel@ has no restriction on the type of values that may be
--     communicated.
--
-- 3.  There is a quasi-duality between the two approaches:  Cloud Haskell's
--     @ReceivePorts@ are special whereas @split-channel@'s @SendPorts@ are
--     special.
--
-- 4.  @ReceivePorts@ can be @'duplicate'd@,  which allows for considerably
--     more efficient publish-subscribe communications than supported by
--     Cloud Haskell at the present time.
--
------------------------------------------------------------------------------

module Control.Concurrent.Chan.Split
     ( SendPort
     , ReceivePort
     , new
     , newSendPort
     , listen
     , duplicate
     , receive
     , send
     , fold
     , unsafeFold
     ) where

import Control.Concurrent.Chan.Split.Implementation
