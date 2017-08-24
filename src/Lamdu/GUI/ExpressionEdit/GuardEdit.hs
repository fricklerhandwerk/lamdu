{-# LANGUAGE NoImplicitPrelude, OverloadedStrings #-}
module Lamdu.GUI.ExpressionEdit.GuardEdit
    ( make
    ) where

import qualified Control.Lens as Lens
import qualified Control.Monad.Reader as Reader
import qualified Data.Map as Map
import           Data.Store.Transaction (Transaction)
import           GUI.Momentu.Align (WithTextPos)
import           GUI.Momentu.Animation (AnimId)
import qualified GUI.Momentu.Element as Element
import qualified GUI.Momentu.EventMap as E
import           GUI.Momentu.Glue ((/|/))
import qualified GUI.Momentu.Responsive as Responsive
import qualified GUI.Momentu.Responsive.Options as ResponsiveOpt
import qualified GUI.Momentu.Responsive.Expression as ResponsiveExpr
import           GUI.Momentu.View (View)
import qualified GUI.Momentu.Widget as Widget
import qualified GUI.Momentu.Widgets.Spacer as Spacer
import qualified Lamdu.Config as Config
import           Lamdu.GUI.ExpressionGui (ExpressionGui)
import qualified Lamdu.GUI.ExpressionGui as ExpressionGui
import           Lamdu.GUI.ExpressionGui.Monad (ExprGuiM)
import qualified Lamdu.GUI.ExpressionGui.Monad as ExprGuiM
import qualified Lamdu.GUI.ExpressionGui.Types as ExprGuiT
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import qualified Lamdu.Sugar.Types as Sugar

import           Lamdu.Prelude

genRow ::
    Monad m =>
    ExprGuiM m (AnimId -> ExpressionGui m -> ExpressionGui m -> ExpressionGui m)
genRow =
    do
        vbox <- Responsive.vboxSpaced
        indent <- ResponsiveExpr.indent
        pure $ \indentAnimId condRow result ->
            vbox [condRow, indent indentAnimId result]
            & ResponsiveOpt.tryWideLayout (ResponsiveOpt.hbox id id) [condRow, result]

makeGuardRow ::
    Monad m =>
    Transaction m Sugar.EntityId -> WithTextPos View -> Sugar.EntityId ->
    ExprGuiM m (ExpressionGui m -> ExpressionGui m -> ExpressionGui m)
makeGuardRow delete prefixLabel entityId =
    do
        label <- ExpressionGui.grammarLabel "if "
        colon <- ExpressionGui.grammarLabel ": "
        config <- Lens.view Config.config
        let eventMap =
                delete <&> WidgetIds.fromEntityId
                & Widget.keysEventMapMovesCursor (Config.delKeys config) (E.Doc ["Edit", "Guard", "Delete"])
        genRow <&> \gen cond result ->
            gen indentAnimId (prefixLabel /|/ label /|/ cond /|/ colon) result
            & E.weakerEvents eventMap
    where
        indentAnimId = WidgetIds.fromEntityId entityId & Widget.toAnimId

makeElseIf ::
    Monad m =>
    Sugar.GuardElseIf m (ExprGuiT.SugarExpr m) ->
    ExprGuiM m (ExpressionGui m) -> ExprGuiM m (ExpressionGui m)
makeElseIf (Sugar.GuardElseIf scopes entityId cond res delete) makeRest =
    do
        mOuterScopeId <- ExprGuiM.readMScopeId
        let mInnerScope = lookupMKey <$> mOuterScopeId <*> scopes
        -- TODO: green evaluation backgrounds, "◗"?
        elseLabel <- ExpressionGui.grammarLabel "else"
        space <- Spacer.stdHSpace
        Responsive.vboxSpaced <*>
            sequence
            [ makeGuardRow delete (elseLabel /|/ space) entityId
                <*> ExprGuiM.makeSubexpression cond
                <*> ExprGuiM.makeSubexpression res
            , makeRest
            ]
            & Reader.local (Element.animIdPrefix .~ Widget.toAnimId (WidgetIds.fromEntityId entityId))
            & ExprGuiM.withLocalMScopeId mInnerScope
    where
        -- TODO: cleaner way to write this?
        lookupMKey k m = k >>= (`Map.lookup` m)

make ::
    Monad m =>
    Sugar.Guard m (ExprGuiT.SugarExpr m) ->
    Sugar.Payload m ExprGuiT.Payload ->
    ExprGuiM m (ExpressionGui m)
make guards pl =
    do
        ifRow <-
            makeGuardRow (guards ^. Sugar.gDeleteIf) Element.empty (pl ^. Sugar.plEntityId)
            <*> ExprGuiM.makeSubexpression (guards ^. Sugar.gIf)
            <*> ExprGuiM.makeSubexpression (guards ^. Sugar.gThen)
        let makeElse =
                (genRow ?? elseAnimId)
                <*>
                ((/|/)
                    <$> ExpressionGui.grammarLabel "else"
                    <*> (ExpressionGui.grammarLabel ": " & Reader.local (Element.animIdPrefix .~ elseAnimId))
                    <&> Responsive.fromTextView
                ) <*> ExprGuiM.makeSubexpression (guards ^. Sugar.gElse)
        elses <- foldr makeElseIf makeElse (guards ^. Sugar.gElseIfs)
        Responsive.vboxSpaced ?? [ifRow, elses]
    & Widget.assignCursor myId (WidgetIds.fromExprPayload (guards ^. Sugar.gIf . Sugar.rPayload))
    & ExpressionGui.stdWrapParentExpr pl
    where
        myId = WidgetIds.fromExprPayload pl
        elseAnimId = Widget.toAnimId elseId
        elseId = WidgetIds.fromExprPayload (guards ^. Sugar.gElse . Sugar.rPayload)