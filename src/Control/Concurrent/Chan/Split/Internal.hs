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
-- This includes atomic sequences of operations,  and playing tricks with
-- ports.  'sendMany' and 'split' were two functions that were in this
-- module as examples,  but I decided to promote them to the public API.
-- If you come up with any new operations and some good use cases for them,
-- let me know and I'll consider including them here or in the public API.
--
-- Note that the usual caveat that the Package Version Policy does not
-- apply to this module.   The interface can change at any time,
-- potentially breaking your code without even causing a compile-time
-- error. 
--
------------------------------------------------------------------------------

module Control.Concurrent.Chan.Split.Internal
     ( SendPort(..)
     , ReceivePort(..)
     , List
     , Item(..)
     , foldList
     ) where

import Control.Concurrent.Chan.Split.Implementation
