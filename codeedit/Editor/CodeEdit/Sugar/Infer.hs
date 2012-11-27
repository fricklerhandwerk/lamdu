{-# LANGUAGE TemplateHaskell, DeriveFunctor #-}
module Editor.CodeEdit.Sugar.Infer
  (
  -- Type-check an expression into an ordinary Inferred Expression,
  -- short-circuit on error:
    inferMaybe

  -- Type-check an expression into a StoredResult:
  , inferLoadedExpression
  , StoredResult(..), srContext, srExpr, srRefmap, srSuccess
  , StoredPayload, splGuid

  -- Convert pure, inferred, stored expressions to Result:
  , resultFromStored, resultFromPure, resultFromInferred
  , Result, resultGuid, resultMInferred, resultIWC, resultProp
  ) where

import Control.Applicative ((<$>), (<$))
import Control.Arrow ((&&&))
import Control.Monad (liftM, void, (<=<))
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.State (StateT)
import Data.Cache (Cache)
import Data.Hashable (hash)
import Data.Store.Guid (Guid)
import Data.Store.Transaction (Transaction)
import Editor.Data.Infer.Conflicts (InferredWithConflicts(..), inferWithConflicts)
import System.Random (RandomGen)
import qualified Control.Lens as Lens
import qualified Control.Lens.TH as LensTH
import qualified Data.Cache as Cache
import qualified Data.Store.Transaction as Transaction
import qualified Data.Traversable as Traversable
import qualified Editor.Data as Data
import qualified Editor.Data.IRef as DataIRef
import qualified Editor.Data.Infer as Infer
import qualified Editor.Data.Load as Load
import qualified System.Random as Random
import qualified System.Random.Utils as RandomUtils

type T = Transaction
type CT m = StateT Cache (T m)

type StoredPayload m =
  InferredWithConflicts (DataIRef.ExpressionProperty (T m))

data StoredResult m = StoredResult
  { _srSuccess :: Bool
  , _srRefmap :: Infer.RefMap
  , _srExpr :: Data.Expression DataIRef.DefinitionIRef (StoredPayload m)
  , _srContext :: Infer.Loaded DataIRef.Expression
  }
LensTH.makeLenses ''StoredResult

type MInferredMStoredPayload m = Maybe (InferredWithConflicts (Maybe (DataIRef.ExpressionProperty (T m))))

data Payload m = Payload
  { plGuid :: Guid
  , plMInferred :: MInferredMStoredPayload m
  }

type Result m = Data.Expression DataIRef.DefinitionIRef (Payload m)

resultFrom ::
  RandomGen g => g -> (a -> MInferredMStoredPayload m) ->
  Data.Expression DataIRef.DefinitionIRef a -> Result m
resultFrom gen f =
    Data.randomizeParamIds paramGen
  . Data.randomizeExpr exprGen
  . (flip Payload . f <$>)
  where
    paramGen : exprGen : _ = RandomUtils.splits gen

-- Not inferred, not stored
resultFromPure :: RandomGen g => g -> Data.Expression DataIRef.DefinitionIRef () -> Result m
resultFromPure gen =
  resultFrom gen (const Nothing)

-- Inferred, but not stored:
resultFromInferred ::
  Data.Expression DataIRef.DefinitionIRef (Infer.Inferred ()) ->
  Data.Expression DataIRef.DefinitionIRef (Payload m)
resultFromInferred expr =
  resultFrom gen f expr
  where
    gen = Random.mkStdGen . hash . show $ void expr
    f inferred =
      Just InferredWithConflicts
      { iwcInferred = Nothing <$ inferred
      , iwcTypeConflicts = []
      , iwcValueConflicts = []
      }

-- Inferred and stored
resultFromStored ::
  Data.Expression DataIRef.DefinitionIRef (StoredPayload m) ->
  Data.Expression DataIRef.DefinitionIRef (Payload m)
resultFromStored expr =
  f <$> expr
  where
    f i = Payload
      { plGuid = splGuid i
      , plMInferred = Just $ Just <$> i
      }

splGuid :: StoredPayload m -> Guid
splGuid = DataIRef.epGuid . Infer.iStored . iwcInferred

resultGuid :: Result m -> Guid
resultGuid = plGuid . Lens.view Data.ePayload

resultMInferred :: Result m -> MInferredMStoredPayload m
resultMInferred = plMInferred . Lens.view Data.ePayload

resultIWC :: Result m -> Maybe (StoredPayload m)
resultIWC = Traversable.sequenceA <=< plMInferred . Lens.view Data.ePayload

resultProp :: Result m -> Maybe (DataIRef.ExpressionProperty (T m))
resultProp = Infer.iStored . iwcInferred <=< plMInferred . Lens.view Data.ePayload

inferredIRefToStored ::
  Monad m => Load.ExpressionSetter (T m) ->
  Data.Expression DataIRef.DefinitionIRef (InferredWithConflicts DataIRef.Expression) ->
  Data.Expression DataIRef.DefinitionIRef (StoredPayload m)
inferredIRefToStored setter expr =
  fmap propIntoInferred . Load.exprAddProp . Load.Stored setter $
  (Infer.iStored . iwcInferred &&& id) <$> expr
  where
    propIntoInferred (prop, iwc) = prop <$ iwc

loader :: Monad m => Infer.Loader (T m)
loader =
  Infer.Loader
  (liftM void . Load.loadExpressionIRef . Data.defType <=<
   Transaction.readIRef)

inferMaybe ::
  Monad m =>
  Data.Expression DataIRef.DefinitionIRef a -> Infer.RefMap ->
  Infer.InferNode -> T m (Maybe (Infer.Expression a))
inferMaybe expr inferContext inferPoint = do
  loaded <- Infer.load loader Nothing expr
  return . fmap fst $
    Infer.inferLoaded (Infer.InferActions (const Nothing))
    loaded inferContext inferPoint

inferLoadedExpression ::
  Monad m =>
  Maybe DataIRef.DefinitionIRef -> Load.Loaded (T m) ->
  (Infer.RefMap, Infer.InferNode) ->
  CT m (StoredResult m)
inferLoadedExpression mDefI (Load.Stored setExpr exprIRef) inferState = do
  loaded <- lift $ Infer.load loader mDefI exprIRef
  (success, refMap, expr) <-
    Cache.memoS (return . uncurriedInfer) (loaded, inferState)
  return StoredResult
    { _srSuccess = success
    , _srRefmap = refMap
    , _srExpr = inferredIRefToStored setExpr expr
    , _srContext = loaded
    }
  where
    uncurriedInfer (loaded, (refMap, inferNode)) =
      inferWithConflicts loaded refMap inferNode
