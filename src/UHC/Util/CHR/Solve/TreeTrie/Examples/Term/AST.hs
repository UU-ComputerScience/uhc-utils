{-# LANGUAGE TypeFamilies, MultiParamTypeClasses, TypeSynonymInstances, FlexibleInstances #-}

{-| Simple term language with some builtin guards and predicates 
 -}

module UHC.Util.CHR.Solve.TreeTrie.Examples.Term.AST
  ( Tm(..)
  , C(..)
  , G(..)
  -- , B(..)
  , P(..)
  , POp(..)
  , E
  , S
  
  , Var
  )
  where

import           UHC.Util.VarLookup
import           UHC.Util.Substitutable
import           UHC.Util.TreeTrie
import           UHC.Util.Pretty as PP
import           UHC.Util.Serialize
import           UHC.Util.CHR.Key
import           UHC.Util.CHR.Base
import           UHC.Util.CHR.Rule
import           UHC.Util.Utils
import           UHC.Util.AssocL
import           UHC.Util.Lens
import           UHC.Util.CHR.GTerm
import           Data.Typeable
import           Data.Maybe
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.List as List
import           Control.Monad
import           Control.Monad.IO.Class
import           Control.Applicative
import qualified UHC.Util.CHR.Solve.TreeTrie.Mono as M
import qualified UHC.Util.CHR.Solve.TreeTrie.MonoBacktrackPrio as MBP

import           UHC.Util.Debug


type Var = String -- Int

data Key
  = Key_Int     !Int            
  | Key_Var     !Var            
  | Key_Str     !String   
  | Key_Op      !POp   
  deriving (Eq, Ord, Show)

instance PP Key where
  pp (Key_Int i) = "ki" >|< ppParens i
  pp (Key_Var v) = "kv" >|< ppParens v
  pp (Key_Str s) = "ks" >|< ppParens s
  pp (Key_Op  o) = "ko" >|< ppParens o

-- | Terms
data Tm
  = Tm_Var Var              -- ^ variable (to be substituted)
  | Tm_Int Int              -- ^ int value (for arithmetic)
  | Tm_Bool Bool            -- ^ bool value
  | Tm_Con String [Tm]      -- ^ general term structure
  | Tm_Op  POp    [Tm]      -- ^ interpretable (when solving) term structure
  deriving (Show, Eq, Ord, Typeable, Generic)

{-
tmIsVar :: Tm -> Maybe Var
tmIsVar (Tm_Var v) = Just v
tmIsVar _          = Nothing
-}

instance VarTerm Tm where
  varTermMbKey (Tm_Var v) = Just v
  varTermMbKey _          = Nothing
  varTermMkKey            = Tm_Var

instance PP Tm where
  pp (Tm_Var v        ) = pp v -- "v" >|< v
  pp (Tm_Con c []     ) = pp c
  pp (Tm_Con c as     ) = ppParens $ c >#< ppSpaces as
  pp (Tm_Op  o [a    ]) = ppParens $ o >#< a
  pp (Tm_Op  o [a1,a2]) = ppParens $ a1 >#< o >#< a2
  pp (Tm_Int i        ) = pp i
  pp (Tm_Bool b       ) = pp b

instance Serialize Tm

-- | Constraint
data C
  = C_Con String [Tm]
  | CB_Eq Tm Tm          -- ^ builtin: unification
  | CB_Ne Tm Tm          -- ^ builtin: non unification
  | CB_Fail              -- ^ explicit fail
  deriving (Show, Eq, Ord, Typeable, Generic)

instance PP C where
  pp (C_Con c as) = c >#< ppSpaces as
  pp (CB_Eq x y ) = "unify" >#< ppSpaces [x,y]
  pp (CB_Ne x y ) = "not-unify" >#< ppSpaces [x,y]
  pp (CB_Fail   ) = pp "fail"

instance Serialize C

-- | Guard
data G
  = G_Eq Tm Tm          -- ^ check for equality
  | G_Ne Tm Tm          -- ^ check for inequality
  | G_Tm Tm             -- ^ determined by arithmetic evaluation
  deriving (Show, Typeable, Generic)

instance PP G where
  pp (G_Eq x y) = "is-eq" >#< ppParensCommas [x,y]
  pp (G_Ne x y) = "is-ne" >#< ppParensCommas [x,y]
  pp (G_Tm t  ) = "eval"  >#< ppParens t

instance Serialize G

type instance TrTrKey Tm = Key
type instance TrTrKey C = Key
type instance TTKey Tm = Key
type instance TTKey C = Key

instance TTKeyable Tm where
  toTTKeyParentChildren' o (Tm_Var v) | ttkoptsVarsAsWild o = (TT1K_Any, ttkChildren [])
                                      | otherwise           = (TT1K_One $ Key_Var v, ttkChildren [])
  toTTKeyParentChildren' o (Tm_Int i) = (TT1K_One $ Key_Int i, ttkChildren [])
  toTTKeyParentChildren' o (Tm_Bool i) = (TT1K_One $ Key_Int $ fromEnum i, ttkChildren [])
  toTTKeyParentChildren' o (Tm_Con c as) = (TT1K_One $ Key_Str c, ttkChildren $ map (toTTKey' o) as)
  toTTKeyParentChildren' o (Tm_Op op as) = (TT1K_One $ Key_Op op, ttkChildren $ map (toTTKey' o) as)

instance TTKeyable C where
  -- Only necessary for non-builtin constraints
  toTTKeyParentChildren' o (C_Con c as) = (TT1K_One $ Key_Str c, ttkChildren $ map (toTTKey' o) as)

type E = ()

-- | Binary operator
data POp
  = 
    -- binary
    PBOp_Add
  | PBOp_Sub
  | PBOp_Mul
  | PBOp_Mod
  | PBOp_Lt
  | PBOp_Le
  
    -- unary
  | PUOp_Abs
  deriving (Eq, Ord, Show, Generic)

instance PP POp where
  pp PBOp_Add = pp "+"
  pp PBOp_Sub = pp "-"
  pp PBOp_Mul = pp "*"
  pp PBOp_Mod = pp "mod"
  pp PBOp_Lt  = pp "<"
  pp PBOp_Le  = pp "<="
  pp PUOp_Abs = pp "abs"

newtype P
  = P_Tm Tm
  deriving (Eq, Ord, Show, Generic)

instance PP P where
  pp (P_Tm t) = pp t

instance Serialize POp

instance Serialize P

instance Bounded P where
  minBound = P_Tm $ Tm_Int $ fromIntegral $ unPrio $ minBound
  maxBound = P_Tm $ Tm_Int $ fromIntegral $ unPrio $ maxBound

type S = Map.Map Var Tm

type instance VarLookupKey S = Var
type instance VarLookupVal S = Tm

instance PP S where
  pp = ppAssocLV . Map.toList

type instance ExtrValVarKey G = Var
type instance ExtrValVarKey C = Var
type instance ExtrValVarKey Tm = Var
type instance ExtrValVarKey P = Var

type instance CHRMatchableKey S = Key

instance VarLookup S where
  varlookupWithMetaLev _ = Map.lookup
  varlookupKeysSetWithMetaLev _ = Map.keysSet
  varlookupSingletonWithMetaLev _ = Map.singleton
  varlookupEmpty = Map.empty

instance VarLookupCmb S S where
  (|+>) = Map.union

instance VarUpdatable S S where
  varUpd = (|+>)

instance VarUpdatable Tm S where
  s `varUpd` t = case fromJust $ varlookupResolveVal varTermMbKey t s <|> return t of
      Tm_Con c as -> Tm_Con c $ map (s `varUpd`) as
      Tm_Op  o as -> Tm_Op  o $ map (s `varUpd`) as
      t -> t

instance VarUpdatable P S where
  s `varUpd` p = case p of
    P_Tm t -> P_Tm (s `varUpd` t)

instance VarUpdatable G S where
  s `varUpd` G_Eq x y = G_Eq (s `varUpd` x) (s `varUpd` y)
  s `varUpd` G_Ne x y = G_Ne (s `varUpd` x) (s `varUpd` y)
  s `varUpd` G_Tm x   = G_Tm (s `varUpd` x)

instance VarUpdatable C S where
  s `varUpd` c = case c of
    C_Con c as -> C_Con c $ map (s `varUpd`) as
    CB_Eq x y  -> CB_Eq (s `varUpd` x) (s `varUpd` y)
    CB_Ne x y  -> CB_Ne (s `varUpd` x) (s `varUpd` y)
    c          -> c

instance VarExtractable Tm where
  varFreeSet (Tm_Var v) = Set.singleton v
  varFreeSet (Tm_Con _ as) = Set.unions $ map varFreeSet as
  varFreeSet (Tm_Op  _ as) = Set.unions $ map varFreeSet as
  varFreeSet _ = Set.empty

instance VarExtractable G where
  varFreeSet (G_Eq x y) = Set.unions [varFreeSet x, varFreeSet y]
  varFreeSet (G_Ne x y) = Set.unions [varFreeSet x, varFreeSet y]
  varFreeSet (G_Tm x  ) = varFreeSet x

instance VarExtractable C where
  varFreeSet (C_Con _ as) = Set.unions $ map varFreeSet as
  varFreeSet (CB_Eq x y ) = Set.unions [varFreeSet x, varFreeSet y]
  varFreeSet _            = Set.empty

instance VarExtractable P where
  varFreeSet (P_Tm t) = varFreeSet t

instance CHREmptySubstitution S where
  chrEmptySubst = Map.empty

instance IsConstraint C where
  cnstrSolvesVia (C_Con _ _) = ConstraintSolvesVia_Rule
  cnstrSolvesVia (CB_Eq _ _) = ConstraintSolvesVia_Solve
  cnstrSolvesVia (CB_Ne _ _) = ConstraintSolvesVia_Solve
  cnstrSolvesVia (CB_Fail  ) = ConstraintSolvesVia_Fail

instance IsCHRGuard E G S where

instance IsCHRConstraint E C S where

instance IsCHRPrio E P S where

instance IsCHRBacktrackPrio E P S where

instance CHRCheckable E G S where
  chrCheckM e g =
    case g of
      G_Eq t1 t2 -> chrUnifyM CHRMatchHow_Check e t1 t2
      G_Ne t1 t2 -> do
        menv <- getl chrmatcherstateEnv
        s <- getl chrmatcherstateVarLookup
        chrmatcherRun'
          (\e -> case e of {CHRMatcherFailure -> chrMatchSuccess; _ -> chrMatchFail})
          (\_ _ _ -> chrMatchFail)
          (chrCheckM e (G_Eq t1 t2)) menv s
      G_Tm t -> do
        e <- tmEval t
        case e of
          Tm_Bool True -> chrMatchSuccess
          _            -> chrMatchFail

instance CHRMatchable E Tm S where
  chrUnifyM how e t1 t2 = chrMatchResolveCompareAndContinue how unif t1 t2
    where
      unif t1 t2  = 
          case (t1, t2) of
            (Tm_Con c1 as1, Tm_Con c2 as2) | c1 == c2 && length as1 == length as2 
                                                                              -> sequence_ (zipWith (chrUnifyM how e) as1 as2)
            (Tm_Op  o1 as1, Tm_Op  o2 as2) | how < CHRMatchHow_Unify && o1 == o2 && length as1 == length as2 
                                                                              -> sequence_ (zipWith (chrUnifyM how e) as1 as2)
            (Tm_Op  o1 as1, t2           ) | how == CHRMatchHow_Unify         -> evop o1 as1 >>= \t1 -> chrUnifyM how e t1 t2
            (t1           , Tm_Op  o2 as2) | how == CHRMatchHow_Unify         -> evop o2 as2 >>= \t2 -> chrUnifyM how e t1 t2
            (Tm_Int i1    , Tm_Int i2    ) | i1 == i2                         -> chrMatchSuccess
            (Tm_Bool b1   , Tm_Bool b2   ) | b1 == b2                         -> chrMatchSuccess
            _                                                                 -> chrMatchFail
        where
          evop = tmEvalOp
          ev = tmEval
{-
  chrUnifyM how e t1 t2 = do
      menv <- getl chrmatcherstateEnv
      case (t1, t2) of
        (Tm_Con c1 as1, Tm_Con c2 as2) | c1 == c2 && length as1 == length as2 
                                                                          -> sequence_ (zipWith (chrUnifyM how e) as1 as2)
        (Tm_Op  o1 as1, Tm_Op  o2 as2) | how < CHRMatchHow_Unify && o1 == o2 && length as1 == length as2 
                                                                          -> sequence_ (zipWith (chrUnifyM how e) as1 as2)
        (Tm_Op  o1 as1, t2           ) | how == CHRMatchHow_Unify         -> evop o1 as1 >>= \t1 -> chrUnifyM how e t1 t2
        (t1           , Tm_Op  o2 as2) | how == CHRMatchHow_Unify         -> evop o2 as2 >>= \t2 -> chrUnifyM how e t1 t2
        (Tm_Int i1    , Tm_Int i2    ) | i1 == i2                         -> chrMatchSuccess
        (Tm_Bool b1   , Tm_Bool b2   ) | b1 == b2                         -> chrMatchSuccess
        (Tm_Var v1    , Tm_Var v2    ) | v1 == v2                         -> chrMatchSuccess
                                       | how == CHRMatchHow_Check         -> varContinue
                                                                               (varContinue (waitv v1 >> waitv v2) (chrUnifyM how e t1) v2)
                                                                               (\t1 -> varContinue (waitt t1 >> waitv v2) (\t2 -> chrUnifyM how e t1 t2) v2)
                                                                               v1
                                       where waitv v = unless (chrmatchenvMetaMayBind menv v) $ chrMatchWait v
                                             waitt (Tm_Var v) = waitv v
                                             waitt  _         = return ()
        (Tm_Var v1    , t2           ) | how == CHRMatchHow_Check         -> varContinue (if maybind then chrMatchFail else chrMatchWait v1) (\t1 -> chrUnifyM how e t1 t2) v1
                                       | how >= CHRMatchHow_Match && maybind
                                                                          -> varContinue (chrMatchBind menv v1 t2) (\t1 -> chrUnifyM how e t1 t2) v1
                                       | otherwise                        -> varContinue chrMatchFail {- chrMatchFailNoBinding -} (\t1 -> chrUnifyM how e t1 t2) v1
                                       where maybind = chrmatchenvMetaMayBind menv v1
        (t1           , Tm_Var v2    ) | how == CHRMatchHow_Check         -> varContinue (if maybind then chrMatchFail else chrMatchWait v2) (chrUnifyM how e t1) v2
                                       | how == CHRMatchHow_MatchAndWait  -> varContinue (chrMatchWait v2) (chrUnifyM how e t1) v2
                                       | how == CHRMatchHow_Unify && maybind
                                                                          -> varContinue (chrMatchBind menv v2 t1) (chrUnifyM how e t1) v2
                                       | otherwise                        -> varContinue chrMatchFail {- chrMatchFailNoBinding -} (chrUnifyM how e t1) v2
                                       where maybind = chrmatchenvMetaMayBind menv v2
        _                                                                 -> chrMatchFail
    where
      varContinue = varlookupResolveAndContinueM varTermMbKey chrMatchSubst
      evop = tmEvalOp
      ev = tmEval
-}

tmEval :: Tm -> CHRMatcher S Tm
tmEval x = case x of
          Tm_Int _    -> return x
          Tm_Var v    -> varlookupResolveAndContinueM varTermMbKey chrMatchSubst chrMatchFailNoBinding tmEval v
          Tm_Op  o xs -> tmEvalOp o xs
          _           -> chrMatchFail

tmEvalOp :: POp -> [Tm] -> CHRMatcher S Tm
tmEvalOp o xs = do
          xs <- forM xs tmEval 
          case (o, xs) of
            (PUOp_Abs, [Tm_Int x]) -> ret $ abs x
            (PBOp_Add, [Tm_Int x, Tm_Int y]) -> ret $ x + y
            (PBOp_Sub, [Tm_Int x, Tm_Int y]) -> ret $ x - y
            (PBOp_Mul, [Tm_Int x, Tm_Int y]) -> ret $ x * y
            (PBOp_Mod, [Tm_Int x, Tm_Int y]) -> ret $ x `mod` y
            (PBOp_Lt , [Tm_Int x, Tm_Int y]) -> retb $ x < y
            (PBOp_Le , [Tm_Int x, Tm_Int y]) -> retb $ x <= y
        where ret  x = return $ Tm_Int  x
              retb x = return $ Tm_Bool x

instance CHRMatchable E C S where
  chrUnifyM how e c1 c2 = do
    case (c1, c2) of
      (C_Con c1 as1, C_Con c2 as2) | c1 == c2 && length as1 == length as2 
        -> sequence_ (zipWith (chrUnifyM how e) as1 as2)
      _ -> chrMatchFail
  chrBuiltinSolveM e b = case b of
    CB_Eq x y -> chrUnifyM CHRMatchHow_Unify e x y
    CB_Ne x y -> do
        menv <- getl chrmatcherstateEnv
        s <- getl chrmatcherstateVarLookup
        chrmatcherRun' (\_ -> chrMatchSuccess) (\_ _ _ -> chrMatchFail) (chrBuiltinSolveM e (CB_Eq x y)) menv s

instance CHRMatchable E P S where
  chrUnifyM how e p1 p2 = do
    case (p1, p2) of
      (P_Tm   t1     , P_Tm   t2     ) -> chrUnifyM how e t1  t2

type instance CHRPrioEvaluatableVal Tm = Prio

instance CHRPrioEvaluatable E Tm S where
  chrPrioEval e s t = case chrmatcherRun' (\_ -> Tm_Int $ fromIntegral $ unPrio $ (minBound :: Prio)) (\_ _ x -> x) (tmEval t) emptyCHRMatchEnv (StackedVarLookup [s]) of
    Tm_Int i -> fromIntegral i
    t        -> minBound
  chrPrioLift = Tm_Int . fromIntegral

type instance CHRPrioEvaluatableVal P = Prio

instance CHRPrioEvaluatable E P S where
  chrPrioEval e s p = case p of
    P_Tm t -> chrPrioEval e s t
  chrPrioLift = P_Tm . chrPrioLift


--------------------------------------------------------

instance GTermAs C G P P Tm where
  asHeadConstraint t = case t of
    GTm_Con c a -> forM a asTm >>= (return . C_Con c)
    t -> gtermasFail t "not a constraint"

  asBodyConstraint t = case t of
    GTm_Con "Fail" [] -> return CB_Fail
    GTm_Con o [a,b] | isJust o' -> do
        a <- asTm a
        b <- asTm b
        return $ fromJust o' a b
      where o' = List.lookup o [("==", CB_Eq), ("/=", CB_Ne)]
    t -> asHeadConstraint t

  asGuard t = case t of
    GTm_Con o [a,b] | isJust o' -> do
        a <- asTm a
        b <- asTm b
        return $ fromJust o' a b
      where o' = List.lookup o [("==", G_Eq), ("/=", G_Ne)]
    t -> fmap G_Tm $ asTm t
    
  asHeadBacktrackPrio = fmap P_Tm . asTm

  asAltBacktrackPrio = asHeadBacktrackPrio
  asRulePrio = asHeadBacktrackPrio

  asTm t = case t of
    GTm_Con "True" [] -> return $ Tm_Bool True
    GTm_Con "False" [] -> return $ Tm_Bool False
    GTm_Con o [a] | isJust o' -> do
        a <- asTm a
        return $ Tm_Op (fromJust o') [a]
      where o' = List.lookup o [("Abs", PUOp_Abs)]
    GTm_Con o [a,b] | isJust o' -> do
        a <- asTm a
        b <- asTm b
        return $ Tm_Op (fromJust o') [a,b]
      where o' = List.lookup o [("+", PBOp_Add), ("-", PBOp_Sub), ("*", PBOp_Mul), ("Mod", PBOp_Mod), ("<", PBOp_Lt), ("<=", PBOp_Le)]
    GTm_Con c a -> forM a asTm >>= (return . Tm_Con c)
    GTm_Var v -> return $ Tm_Var v
    GTm_Int i -> return $ Tm_Int (fromInteger i)
    t -> gtermasFail t "not a term"

--------------------------------------------------------
-- leq example, backtrack prio specific

instance MBP.IsCHRSolvable E C G P P S

instance MBP.MonoBacktrackPrio C G P P S E IO

