{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImpredicativeTypes #-} -- See Note [Impredicative Σ?]
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Data.Singletons.Sigma
-- Copyright   :  (C) 2017 Ryan Scott
-- License     :  BSD-style (see LICENSE)
-- Maintainer  :  Ryan Scott
-- Stability   :  experimental
-- Portability :  non-portable
--
-- Defines 'Sigma', a dependent pair data type, and related functions.
--
----------------------------------------------------------------------------

module Data.Singletons.Sigma
    ( Sigma(..), Σ
    , projSigma1, projSigma2
    , mapSigma, zipSigma
    ) where

import Data.Kind (Type)
import Data.Singletons.Internal

-- | A dependent pair.
data Sigma (s :: Type) :: (s ~> Type) -> Type where
  (:&:) :: forall s t fst. Sing (fst :: s) -> t @@ fst -> Sigma s t
infixr 4 :&:

-- | Unicode shorthand for 'Sigma'.
type Σ = Sigma

{-
Note [Impredicative Σ?]
~~~~~~~~~~~~~~~~~~~~~~~
The definition of Σ currently will not typecheck without the use of
ImpredicativeTypes. There isn't a fundamental reason that this should be the
case, and the only reason that GHC currently requires this is due to Trac
#13408. If someone ever fixes that bug, we could remove the use of
ImpredicativeTypes.
-}

-- | Project the first element out of a dependent pair.
projSigma1 :: forall s t. SingKind s => Sigma s t -> Demote s
projSigma1 (a :&: _) = fromSing a

-- | Project the second element out of a dependent pair.
--
-- In an ideal setting, the type of 'projSigma2' would be closer to:
--
-- @
-- 'projSigma2' :: 'Sing' (sig :: 'Sigma' s t) -> t @@ ProjSigma1 sig
-- @
--
-- But promoting 'projSigma1' to a type family is not a simple task. Instead,
-- we do the next-best thing, which is to use Church-style elimination.
projSigma2 :: forall s t r. (forall (fst :: s). t @@ fst -> r) -> Sigma s t -> r
projSigma2 f ((_ :: Sing (fst :: s)) :&: b) = f @fst b

-- | Map across a 'Sigma' value in a dependent fashion.
mapSigma :: Sing (f :: a ~> b) -> (forall (x :: a). p @@ x -> q @@ (f @@ x))
         -> Sigma a p -> Sigma b q
mapSigma f g ((x :: Sing (fst :: a)) :&: y) = (f @@ x) :&: (g @fst y)

-- | Zip two 'Sigma' values together in a dependent fashion.
zipSigma :: Sing (f :: a ~> b ~> c)
         -> (forall (x :: a) (y :: b). p @@ x -> q @@ y -> r @@ (f @@ x @@ y))
         -> Sigma a p -> Sigma b q -> Sigma c r
zipSigma f g ((a :: Sing (fstA :: a)) :&: p) ((b :: Sing (fstB :: b)) :&: q) =
  (f @@ a @@ b) :&: (g @fstA @fstB p q)
