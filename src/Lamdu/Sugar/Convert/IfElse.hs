-- | "if" sugar/guards conversion
module Lamdu.Sugar.Convert.IfElse (convertIfElse) where

import qualified Control.Lens.Extended as Lens
import qualified Data.Property as Property
import           Lamdu.Builtins.Anchors (boolTid, trueTag, falseTag)
import qualified Lamdu.Calc.Type as T
import           Lamdu.Data.Anchors (bParamScopeId)
import           Lamdu.Expr.IRef (ValI)
import qualified Lamdu.Infer as Infer
import qualified Lamdu.Sugar.Convert.Input as Input
import           Lamdu.Sugar.Internal
import qualified Lamdu.Sugar.Internal.EntityId as EntityId
import           Lamdu.Sugar.Types
import           Revision.Deltum.Transaction (Transaction)

import           Lamdu.Prelude

type T = Transaction

convertIfElse ::
    Functor m =>
    (ValI m -> T m (ValI m)) ->
    Case InternalName (T m) (T m) (ExpressionU m a) ->
    Maybe (IfElse InternalName (T m) (T m) (ConvertPayload m a))
convertIfElse setToVal caseBody =
    do
        arg <- caseBody ^? cKind . _CaseWithArg . caVal
        case arg ^. _PNode . val of
            BodyFromNom nom | nom ^. nTId . tidTId == boolTid -> tryIfElse (nom ^. nVal)
            _ | arg ^? _PNode . ann . pInput . Input.inferred . Infer.plType . T._TInst . _1 == Just boolTid ->
                tryIfElse arg
            _ -> Nothing
    where
        tryIfElse cond =
            case caseBody ^. cBody . cItems of
            [alt0, alt1]
                | tagOf alt0 == trueTag && tagOf alt1 == falseTag -> convIfElse cond alt0 alt1
                | tagOf alt1 == trueTag && tagOf alt0 == falseTag -> convIfElse cond alt1 alt0
            _ -> Nothing
        tagOf alt = alt ^. ciTag . tagInfo . tagVal
        convIfElse cond altTrue altFalse =
            Just IfElse
            { _iIf = cond
            , _iThen = altTrue ^. ciExpr
            , _iElse =
                case altFalse ^@?
                     ciExpr . _PNode . val . _BodyLam . lamFunc . Lens.selfIndex
                     <. (fBody . _PNode . val . _BinderExpr . _BodyIfElse)
                of
                Just (binder, innerIfElse) ->
                    ElseIf ElseIfContent
                    { _eiScopes =
                        case binder ^. fBodyScopes of
                        SameAsParentScope -> error "lambda body should have scopes"
                        BinderBodyScope x -> x <&> Lens.mapped %~ getScope
                    , _eiContent = innerIfElse
                    }
                    where
                        getScope [x] = x ^. bParamScopeId
                        getScope _ = error "if-else evaluated more than once in same scope?"
                Nothing ->
                    altFalse ^. ciExpr . _PNode . val
                    & _BodyHole . holeMDelete ?~ elseDel
                    & _BodyLam . lamFunc . fBody . _PNode . val . _BinderExpr .
                        _BodyHole . holeMDelete ?~ elseDel
                    & SimpleElse
                & Node (altFalse ^. ciExpr . _PNode . ann)
                & PNode
            }
            where
                elseDel = setToVal (delTarget altTrue) <&> EntityId.ofValI
                delTarget alt =
                    alt ^? ciExpr . _PNode . val . _BodyLam . lamFunc . fBody
                    . _PNode . Lens.filteredBy (val . _BinderExpr) . ann
                    & fromMaybe (alt ^. ciExpr . _PNode . ann)
                    & (^. pInput . Input.stored . Property.pVal)
