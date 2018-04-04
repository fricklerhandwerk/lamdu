{-# LANGUAGE TemplateHaskell, RecordWildCards #-}
module Lamdu.Sugar.Types.Binder
    ( -- Annotations
      Annotation(..), aInferredType, aMEvaluationResult
    -- Node actions
    , DetachAction(..), _FragmentAlready, _FragmentExprAlready, _DetachAction
    , NodeActions(..), detach, mSetToHole, extract, mReplaceParent, wrapInRecord
    -- Let
    , ExtractDestination(..)
    , LetActions(..), laDelete, laNodeActions
    , Let(..)
        , lEntityId, lValue, lName, lUsages
        , lActions, lAnnotation, lBodyScope, lBody
    -- Binders
    , AddNextParam(..), _AddNext, _NeedToPickTagToAddNext
    , FuncParamActions(..), fpAddNext, fpDelete, fpMOrderBefore, fpMOrderAfter
    , ParamInfo(..), piActions, piTag
    , FuncParam(..), fpInfo, fpAnnotation
    , Meta.SpecialArgs(..)
    , Meta.DefinitionState(..)
    , BinderActions(..), baAddFirstParam, baMNodeActions
    , NullParamActions(..), npDeleteLambda
    , AddFirstParam(..), _AddInitialParam, _PrependParam, _NeedToPickTagToAddFirst
    , BinderParams(..), _BinderWithoutParams, _NullParam, _Params
    , BinderParamScopeId(..), bParamScopeId
    , BinderBody(..), bbAddOuterLet, bbContent
    , BinderContent(..), _BinderLet, _BinderExpr
    , BinderBodyScope(..)
    , Binder(..)
        , bChosenScopeProp, bParams, bBody
        , bLamId, bActions, bBodyScopes
    ) where

import qualified Control.Lens as Lens
import           Data.Property (Property)
import           Lamdu.Data.Anchors (BinderParamScopeId(..), bParamScopeId)
import qualified Lamdu.Data.Meta as Meta
import           Lamdu.Sugar.Internal.EntityId (EntityId)
import           Lamdu.Sugar.Types.Eval
import           Lamdu.Sugar.Types.Tag
import           Lamdu.Sugar.Types.Type

import           Lamdu.Prelude

data Annotation name = Annotation
    { _aInferredType :: Type name
    , _aMEvaluationResult :: EvaluationScopes name
    } deriving Show

data AddNextParam name i o
    = AddNext (TagSelection name i o ())
    | -- When the param has anon tag one can't add another one,
      -- contains the EntityId of the param requiring tag.
      NeedToPickTagToAddNext EntityId

data FuncParamActions name i o =
    FuncParamActions
    { _fpAddNext :: AddNextParam name i o
    , _fpDelete :: o ()
    , _fpMOrderBefore :: Maybe (o ())
    , _fpMOrderAfter :: Maybe (o ())
    }

newtype NullParamActions o = NullParamActions
    { _npDeleteLambda :: o ()
    }

data ParamInfo name i o = ParamInfo
    { _piTag :: Tag name i o
    , _piActions :: FuncParamActions name i o
    }

data FuncParam name info = FuncParam
    { _fpAnnotation :: Annotation name
    , _fpInfo :: info
    } deriving (Functor, Foldable, Traversable)

instance (Show info, Show name) => Show (FuncParam name info) where
    show FuncParam{..} =
        "(FuncParam " ++ show _fpInfo ++
        " " ++ show _fpAnnotation ++ " )"

data ExtractDestination
    = ExtractToLet EntityId
    | ExtractToDef EntityId

data DetachAction o
    = FragmentAlready EntityId -- I'o an apply-of-hole, no need to detach
    | FragmentExprAlready EntityId -- I'o an arg of apply-of-hole, no need to detach
    | DetachAction (o EntityId) -- Detach me

data NodeActions name i o = NodeActions
    { _detach :: DetachAction o
    , _mSetToHole :: Maybe (o EntityId) -- (Not available for holes)
    , _extract :: o ExtractDestination
    , _mReplaceParent :: Maybe (o EntityId)
    , _wrapInRecord :: TagSelection name i o ()
    }

data LetActions name i o = LetActions
    { _laDelete :: o ()
    , _laNodeActions :: NodeActions name i o
    }

data Let name i o expr = Let
    { _lValue :: Binder name i o expr -- "let [[foo = bar]] in x"
    , _lEntityId :: EntityId
    , _lUsages :: [EntityId]
    , _lAnnotation :: Annotation name
    , _lName :: Tag name i o
    , _lActions :: LetActions name i o
    , _lBodyScope :: ChildScopes
    , _lBody :: BinderBody name i o expr -- "let foo = bar in [[x]]"
    } deriving (Functor, Foldable, Traversable)

data AddFirstParam name i o
    = -- The inital param is created with anon-tag
      AddInitialParam (o EntityId)
    | PrependParam (TagSelection name i o ())
    | -- When the param has anon tag one can't add another one,
      -- contains the EntityId of the param requiring tag.
      NeedToPickTagToAddFirst EntityId

data BinderActions name i o = BinderActions
    { _baAddFirstParam :: AddFirstParam name i o
    , _baMNodeActions :: Maybe (NodeActions name i o)
    }

data BinderParams name i o
    = -- a definition or let-item without parameters
      BinderWithoutParams
    | -- null param represents a lambda whose parameter's type is inferred
      -- to be the empty record.
      -- This is often used to represent "deferred execution"
      NullParam (FuncParam name (NullParamActions o))
    | Params [FuncParam name (ParamInfo name i o)]

data BinderContent name i o expr
    = BinderLet (Let name i o expr)
    | BinderExpr expr
    deriving (Functor, Foldable, Traversable)

data BinderBody name i o expr = BinderBody
    { _bbAddOuterLet :: o EntityId
    , _bbContent :: BinderContent name i o expr
    } deriving (Functor, Foldable, Traversable)

data BinderBodyScope
    = SameAsParentScope
      -- ^ no binder params
    | BinderBodyScope ParamScopes
      -- ^ binder has params, use the map to get the param application
      -- scopes

data Binder name i o expr = Binder
    { _bChosenScopeProp :: i (Property o (Maybe BinderParamScopeId))
    , _bParams :: BinderParams name i o
    , _bLamId :: Maybe EntityId
    , _bBody :: BinderBody name i o expr
    , _bActions :: BinderActions name i o
    , -- The scope inside a lambda (if exists)
      _bBodyScopes :: BinderBodyScope
    } deriving (Functor, Foldable, Traversable)

Lens.makeLenses ''Annotation
Lens.makeLenses ''Binder
Lens.makeLenses ''BinderActions
Lens.makeLenses ''BinderBody
Lens.makeLenses ''FuncParam
Lens.makeLenses ''FuncParamActions
Lens.makeLenses ''Let
Lens.makeLenses ''LetActions
Lens.makeLenses ''NodeActions
Lens.makeLenses ''NullParamActions
Lens.makeLenses ''ParamInfo
Lens.makePrisms ''AddFirstParam
Lens.makePrisms ''AddNextParam
Lens.makePrisms ''BinderContent
Lens.makePrisms ''BinderParams
Lens.makePrisms ''DetachAction
