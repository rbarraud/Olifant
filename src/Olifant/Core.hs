{-|
Module      : Olifant.Core
Description : Core languages of the compiler
-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeSynonymInstances       #-}

module Olifant.Core where

import Data.String
import Protolude        hiding ((<>))
import Text.Parsec      (ParseError)
import Text.PrettyPrint

-- | All the known types
--
-- TUnit exists only as a placeholder for earlier partially typed languages. 2
-- kinds of types are ideal, but that would be so much confusion, name
-- collisions and boilerplate.
-- [TODO] - Replace TArrow with ~>
data Ty
    = TUnit
    | TInt
    | TBool
    | TArrow Ty Ty
    deriving (Eq, Ord, Show)

-- | Calculus, the frontend language
--
-- Extremely liberal, partially typed and recursive.
data Calculus
    = CVar Text
    | CNumber Int
    | CBool Bool
    | CApp Calculus [Calculus]
    | CLam [(Ty, Text)] Calculus
    | CLet Text Calculus
    deriving (Eq, Show)

-- * The core language
--
-- Core is a reasonably verbose IR, suitable enough for most passes. It is
-- recursive, not perfectly type safe and contains redundant type information in
-- the AST for the verifier. For example, the type parameter in both `App` and
-- `Lam` can be fetched as well as derived. They should always match, and if it
-- doesn't; something went wrong somewhere.
--
-- References:
--
-- https://ghc.haskell.org/trac/ghc/wiki/Commentary/Compiler/CoreSynType
-- http://blog.ezyang.com/2013/05/the-ast-typing-problem/

-- | Variable Scope
--
-- Code treats local and global variables differently. A scope type with and
-- without unit can be disambiguate at compile time, but that is for some other
-- day.
data Scope = Local | Global | Unit
    deriving (Eq, Ord, Show)

-- | A reference type
data Ref = Ref
    { rname :: Text   -- ^ User defined name of the variable
    , ri    :: Int    -- ^ Disambiguate the same name. Eg, a0, a1, a2
    , rty   :: Ty     -- ^ Type of the reference
    , rscope :: Scope -- ^ Is the variable local, global or unknown?
    } deriving (Eq, Ord, Show)

-- | An inner level value of Core
data Expr
    = Var Ref
    | Number Int
    | Bool Bool
    | App Ty Expr [Expr]
    | Lam Ty [Ref] Expr
    deriving (Eq, Show)

-- | Top level binding of a lambda calc expression to a name
data Bind = Bind Ref Expr
    deriving (Eq, Show)

-- | A program is a list of bindings and an expression
data Progn = Progn [Bind] Expr
    deriving (Eq, Show)

-- * The machine language
--
-- The obvious step before code generation.
-- 1. SSA, No compound expressions
-- 2. Not a recursive grammar
-- 3. Nothing that cant be trivially translated to LLVM
data Mach = Mach

-- * Type helpers
ty :: Expr -> Ty
ty (Var ref) = rty ref
ty (Number _)        = TInt
ty (Bool _)          = TBool
ty (App t _ _)       = t
ty (Lam t _ _)       = t

-- | Return type of a type
retT :: Ty -> Ty
retT (TArrow _ tb) = retT tb
retT t             = t

-- | Arguments of a type
argT :: Ty -> Ty
argT (TArrow ta _) = ta
argT t             = t

-- | Arguments of a type
arity :: Ty -> Int
arity (TArrow _ t) = 1 + arity t
arity _            = 0

-- | Make function type out of the argument types & body type
unapply :: Ty -> [Ty] -> Ty
unapply = foldr TArrow

-- | Apply a type to a function
--
-- > apply (TArrow [TInt, TBool]) [TInt]
-- > TBool
apply :: Ty -> [Ty] -> Maybe Ty
apply t [] = Just t
apply (TArrow ta tb) (t:ts)
    | t == ta = apply tb ts
    | otherwise = Nothing
apply _ _ = Nothing

-- * Error handling and state monad
--
-- | Errors raised by the compiler
--
data Error
    = GenError Text
    | Panic Text
    | ParseError ParseError
    | SyntaxError Text
    | UndefinedError Ref
    | TyError -- {expr :: Expr, expected :: Ty, reality :: Ty}
    deriving (Eq, Show)

-- Olifant Monad
--
-- A `State + Error + IO` transformer with Error type fixed to `Error`
newtype Olifant s a = Olifant
    { runOlifant :: StateT s (Except Error) a
    } deriving (Applicative, Functor, Monad, MonadError Error, MonadState s)

-- | Run a computation in olifant monad with some state and return the result
evalM :: Olifant s a -> s -> Either Error a
evalM c s = runIdentity $ runExceptT $ evalStateT (runOlifant c) s

-- | Run a computation in olifant monad with some state and return new state
execM :: Olifant s a -> s -> Either Error s
execM c s = runIdentity $ runExceptT $ execStateT (runOlifant c) s

-- * Instance declarations
instance IsString Ref where
    fromString x = Ref (toS x) 0 TUnit Unit

-- * Pretty printer
--
-- These functions are in core to avoid circular dependency between core and
-- pretty printer module.
arrow, dot, lambda, lett :: Doc
arrow = char '→'
lambda = char 'λ'
dot = char '.'
lett = text "let"

class D a where
    p :: a -> Doc

instance D Ref where
    p (Ref n i t Unit)   = char '$' <> text (toS n) <> int i <> colon <> p t
    p (Ref n i t Local)  = char '%' <> text (toS n) <> int i <> colon <> p t
    p (Ref n i t Global) = char '@' <> text (toS n) <> int i <> colon <> p t

-- [TODO] - Fix type pretty printer for higher order functions
instance D Ty where
    p TUnit          = "∅"
    p TInt           = "i"
    p TBool          = "b"
    p (TArrow ta tb) = p ta <> arrow <> p tb

instance D Expr where
    p (Var ref)    = p ref
    p (Number n)   = int n
    p (Bool True)  = "#t"
    p (Bool False) = "#t"
    p (App _ f e)  = p f <+> p e
    p (Lam _ r e)  = lambda <> p r <> dot <> p e

-- [TODO] - Add type to pretty printed version of let binding
instance D Bind where
    p (Bind r val) = lett <+> p r <+> equals <+> p val

instance D a => D [a] where
    p xs = vcat $ map p xs
