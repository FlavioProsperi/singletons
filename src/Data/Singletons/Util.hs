{- Data/Singletons/Util.hs

(c) Richard Eisenberg 2013
eir@cis.upenn.edu

This file contains helper functions internal to the singletons package.
Users of the package should not need to consult this file.
-}

{-# LANGUAGE CPP, TypeSynonymInstances, FlexibleInstances, RankNTypes,
             TemplateHaskell, GeneralizedNewtypeDeriving,
             MultiParamTypeClasses, StandaloneDeriving,
             UndecidableInstances, MagicHash, UnboxedTuples,
             LambdaCase #-}

module Data.Singletons.Util where

import Prelude hiding ( exp, foldl, concat, mapM, any )
import Language.Haskell.TH.Syntax hiding ( lift )
import Language.Haskell.TH.Desugar
import Data.Char
import Control.Monad hiding ( mapM )
import Control.Monad.Writer hiding ( mapM )
import Control.Monad.Reader hiding ( mapM )
import qualified Data.Map as Map
import Data.Foldable
import Data.Traversable

#if __GLASGOW_HASKELL__ < 709
import Control.Applicative
import GHC.Exts ( Int(I#) )
#endif

-- The list of types that singletons processes by default
basicTypes :: [Name]
basicTypes = [ ''Maybe
             , ''[]
             , ''Either
             ] ++ boundedBasicTypes

boundedBasicTypes :: [Name]
boundedBasicTypes = [ ''Bool
             , ''Ordering
             , ''()
             , ''(,)
             , ''(,,)
             , ''(,,,)
             , ''(,,,,)
             , ''(,,,,,)
             , ''(,,,,,,)
            ]

-- like reportWarning, but generalized to any DsMonad
qReportWarning :: DsMonad q => String -> q ()
qReportWarning = qReport False

-- like reportError, but generalized to any DsMonad
qReportError :: DsMonad q => String -> q ()
qReportError = qReport True

-- | Generate a new Unique
qNewUnique :: DsMonad q => q Int
qNewUnique = do
  Name _ flav <- qNewName "x"
  case flav of
#if __GLASGOW_HASKELL__ >= 709
    NameU n -> return n
#else
    NameU n -> return (I# n)
#endif
    _       -> error "Internal error: `qNewName` didn't return a NameU"

checkForRep :: DsMonad q => [Name] -> q ()
checkForRep names =
  when (any ((== "Rep") . nameBase) names)
    (fail $ "A data type named <<Rep>> is a special case.\n" ++
            "Promoting it will not work as expected.\n" ++
            "Please choose another name for your data type.")

checkForRepInDecls :: DsMonad q => [DDec] -> q ()
checkForRepInDecls decls =
  checkForRep (allNamesIn decls)

tysOfConFields :: DConFields -> [DType]
tysOfConFields (DNormalC stys) = map snd stys
tysOfConFields (DRecC vstys)   = map (\(_,_,ty) -> ty) vstys

-- extract the name and number of arguments to a constructor
extractNameArgs :: DCon -> (Name, Int)
extractNameArgs = liftSnd length . extractNameTypes

-- extract the name and types of constructor arguments
extractNameTypes :: DCon -> (Name, [DType])
extractNameTypes (DCon _ _ n fields) = (n, tysOfConFields fields)

-- is an identifier uppercase?
isUpcase :: Name -> Bool
isUpcase n = let first = head (nameBase n) in isUpper first || first == ':'

-- make an identifier uppercase
upcase :: Name -> Name
upcase = mkName . toUpcaseStr noPrefix

-- make an identifier uppercase and return it as a String
toUpcaseStr :: (String, String)  -- (alpha, symb) prefixes to prepend
            -> Name -> String
toUpcaseStr (alpha, symb) n
  | isHsLetter first
  = upcase_alpha

  | otherwise
  = upcase_symb

  where
    str   = nameBase n
    first = head str

    upcase_alpha = alpha ++ (toUpper first) : tail str

    upcase_symb
      |  first == ':'
      || first == '$' -- special case to avoid name clashes. See #29
      = symb ++ str
      | otherwise
      = symb ++ ':' : str

noPrefix :: (String, String)
noPrefix = ("", "")

-- make an identifier lowercase
locase :: Name -> Name
locase n =
  let str = nameBase n
      first = head str in
    if isHsLetter first
     then mkName ((toLower first) : tail str)
     else mkName (tail str) -- remove the ":"

-- put an uppercase prefix on a name. Takes two prefixes: one for identifiers
-- and one for symbols
prefixUCName :: String -> String -> Name -> Name
prefixUCName pre tyPre n = case (nameBase n) of
    (':' : rest) -> mkName (tyPre ++ rest)
    alpha -> mkName (pre ++ alpha)

-- put a lowercase prefix on a name. Takes two prefixes: one for identifiers
-- and one for symbols
prefixLCName :: String -> String -> Name -> Name
prefixLCName pre tyPre n =
  let str = nameBase n
      first = head str in
    if isHsLetter first
     then mkName (pre ++ str)
     else mkName (tyPre ++ str)

suffixName :: String -> String -> Name -> Name
suffixName ident symb n =
  let str = nameBase n
      first = head str in
  if isHsLetter first
  then mkName (str ++ ident)
  else mkName (str ++ symb)

-- convert a number into both alphanumeric and symoblic forms
uniquePrefixes :: String   -- alphanumeric prefix
               -> String   -- symbolic prefix
               -> Int
               -> (String, String)  -- (alphanum, symbolic)
uniquePrefixes alpha symb n = (alpha ++ n_str, symb ++ convert n_str)
  where
    n_str = show n

    convert [] = []
    convert (d : ds) =
      let d' = case d of
                 '0' -> '!'
                 '1' -> '#'
                 '2' -> '$'
                 '3' -> '%'
                 '4' -> '&'
                 '5' -> '*'
                 '6' -> '+'
                 '7' -> '.'
                 '8' -> '/'
                 '9' -> '<'
                 _   -> error "non-digit in show #"
      in d' : convert ds

-- extract the kind from a TyVarBndr. Returns '*' by default.
extractTvbKind :: DTyVarBndr -> Maybe DKind
extractTvbKind (DPlainTV _) = Nothing
extractTvbKind (DKindedTV _ k) = Just k

-- extract the name from a TyVarBndr.
extractTvbName :: DTyVarBndr -> Name
extractTvbName (DPlainTV n) = n
extractTvbName (DKindedTV n _) = n

-- use the kind provided, or make a fresh kind variable
inferKind :: DsMonad q => Maybe DKind -> q (Maybe DKind)
inferKind (Just k) = return $ Just k
#if __GLASGOW_HASKELL__ < 707
inferKind Nothing = do
  newK <- qNewName "k"
  return $ Just $ DVarK newK
#else
inferKind Nothing = return Nothing
#endif

-- Get argument types from an arrow type. Removing ForallT is an
-- important preprocessing step required by promoteType.
unravel :: DType -> ([DPred], [DType])
unravel (DForallT _ cxt ty) =
  let (cxt', tys) = unravel ty in
  (cxt ++ cxt', tys)
unravel (DAppT (DAppT DArrowT t1) t2) =
  let (cxt, tys) = unravel t2 in
  (cxt, t1 : tys)
unravel t = ([], [t])

-- Reconstruct arrow kind from the list of kinds
ravel :: [DType] -> DType
ravel []    = error "Internal error: raveling nil"
ravel [k]   = k
ravel (h:t) = DAppT (DAppT DArrowT h) (ravel t)

-- count the number of arguments in a type
countArgs :: DType -> Int
countArgs ty = length (snd $ unravel ty) - 1

addStar :: DKind -> DKind
addStar t = DArrowK t DStarK

addStar_maybe :: Maybe DKind -> Maybe DKind
addStar_maybe t = DArrowK <$> t <*> pure DStarK

-- apply a type to a list of types
foldType :: DType -> [DType] -> DType
foldType = foldl DAppT

-- apply an expression to a list of expressions
foldExp :: DExp -> [DExp] -> DExp
foldExp = foldl DAppE

-- is a kind a variable?
isVarK :: DKind -> Bool
isVarK (DVarK _) = True
isVarK _ = False

-- is a function type?
isFunTy :: DType -> Bool
isFunTy (DAppT (DAppT DArrowT _) _) = True
isFunTy (DForallT _ _ _)            = True
isFunTy _                           = False

-- choose the first non-empty list
orIfEmpty :: [a] -> [a] -> [a]
orIfEmpty [] x = x
orIfEmpty x  _ = x

-- an empty list of matches, compatible with GHC 7.6.3
emptyMatches :: [DMatch]
emptyMatches = [DMatch DWildPa (DAppE (DVarE 'error) (DLitE (StringL errStr)))]
  where errStr = "Empty case reached -- this should be impossible"

-- build a pattern match over several expressions, each with only one pattern
multiCase :: [DExp] -> [DPat] -> DExp -> DExp
multiCase [] [] body = body
multiCase scruts pats body =
  DCaseE (mkTupleDExp scruts) [DMatch (mkTupleDPat pats) body]

-- Make a desugar function into a TH function.
wrapDesugar :: (Desugar th ds, DsMonad q) => (th -> ds -> q ds) -> th -> q th
wrapDesugar f th = do
  ds <- desugar th
  fmap sweeten $ f th ds

-- a monad transformer for writing a monoid alongside returning a Q
newtype QWithAux m q a = QWA { runQWA :: WriterT m q a }
  deriving ( Functor, Applicative, Monad, MonadTrans
           , MonadWriter m, MonadReader r )

-- make a DsMonad instance for easy lifting
instance (Quasi q, Monoid m) => Quasi (QWithAux m q) where
  qNewName          = lift `comp1` qNewName
  qReport           = lift `comp2` qReport
  qLookupName       = lift `comp2` qLookupName
  qReify            = lift `comp1` qReify
  qReifyInstances   = lift `comp2` qReifyInstances
  qLocation         = lift qLocation
  qRunIO            = lift `comp1` qRunIO
  qAddDependentFile = lift `comp1` qAddDependentFile
#if __GLASGOW_HASKELL__ >= 707
  qReifyRoles       = lift `comp1` qReifyRoles
  qReifyAnnotations = lift `comp1` qReifyAnnotations
  qReifyModule      = lift `comp1` qReifyModule
  qAddTopDecls      = lift `comp1` qAddTopDecls
  qAddModFinalizer  = lift `comp1` qAddModFinalizer
  qGetQ             = lift qGetQ
  qPutQ             = lift `comp1` qPutQ
#endif

  qRecover exp handler = do
    (result, aux) <- lift $ qRecover (evalForPair exp) (evalForPair handler)
    tell aux
    return result

instance (DsMonad q, Monoid m) => DsMonad (QWithAux m q) where
  localDeclarations = lift localDeclarations

-- helper functions for composition
comp1 :: (b -> c) -> (a -> b) -> a -> c
comp1 = (.)

comp2 :: (c -> d) -> (a -> b -> c) -> a -> b -> d
comp2 f g a b = f (g a b)

-- run a computation with an auxiliary monoid, discarding the monoid result
evalWithoutAux :: Quasi q => QWithAux m q a -> q a
evalWithoutAux = liftM fst . runWriterT . runQWA

-- run a computation with an auxiliary monoid, returning only the monoid result
evalForAux :: Quasi q => QWithAux m q a -> q m
evalForAux = execWriterT . runQWA

-- run a computation with an auxiliary monoid, return both the result
-- of the computation and the monoid result
evalForPair :: Quasi q => QWithAux m q a -> q (a, m)
evalForPair = runWriterT . runQWA

-- in a computation with an auxiliary map, add a binding to the map
addBinding :: (Quasi q, Ord k) => k -> v -> QWithAux (Map.Map k v) q ()
addBinding k v = tell (Map.singleton k v)

-- in a computation with an auxiliar list, add an element to the list
addElement :: Quasi q => elt -> QWithAux [elt] q ()
addElement elt = tell [elt]

-- lift concatMap into a monad
-- could this be more efficient?
concatMapM :: (Monad monad, Monoid monoid, Traversable t)
           => (a -> monad monoid) -> t a -> monad monoid
concatMapM fn list = do
  bss <- mapM fn list
  return $ fold bss

-- make a one-element list
listify :: a -> [a]
listify = (:[])

fstOf3 :: (a,b,c) -> a
fstOf3 (a,_,_) = a

liftFst :: (a -> b) -> (a, c) -> (b, c)
liftFst f (a, c) = (f a, c)

liftSnd :: (a -> b) -> (c, a) -> (c, b)
liftSnd f (c, a) = (c, f a)

snocView :: [a] -> ([a], a)
snocView [] = error "snocView nil"
snocView [x] = ([], x)
snocView (x : xs) = liftFst (x:) (snocView xs)

partitionWith :: (a -> Either b c) -> [a] -> ([b], [c])
partitionWith f = go [] []
  where go bs cs []     = (reverse bs, reverse cs)
        go bs cs (a:as) =
          case f a of
            Left b  -> go (b:bs) cs as
            Right c -> go bs (c:cs) as

partitionWithM :: Monad m => (a -> m (Either b c)) -> [a] -> m ([b], [c])
partitionWithM f = go [] []
  where go bs cs []     = return (reverse bs, reverse cs)
        go bs cs (a:as) = do
          fa <- f a
          case fa of
            Left b  -> go (b:bs) cs as
            Right c -> go bs (c:cs) as

partitionLetDecs :: [DDec] -> ([DLetDec], [DDec])
partitionLetDecs = partitionWith (\case DLetDec ld -> Left ld
                                        dec        -> Right dec)

mapAndUnzip3M :: Monad m => (a -> m (b,c,d)) -> [a] -> m ([b],[c],[d])
mapAndUnzip3M _ []     = return ([],[],[])
mapAndUnzip3M f (x:xs) = do
    (r1,  r2,  r3)  <- f x
    (rs1, rs2, rs3) <- mapAndUnzip3M f xs
    return (r1:rs1, r2:rs2, r3:rs3)

-- is it a letter or underscore?
isHsLetter :: Char -> Bool
isHsLetter c = isLetter c || c == '_'
