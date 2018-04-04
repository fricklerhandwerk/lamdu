{-# LANGUAGE FlexibleContexts #-}
module Lamdu.GUI.ExpressionEdit.RecordEdit
    ( make
    ) where

import qualified Control.Lens as Lens
import qualified Control.Monad.Reader as Reader
import qualified Data.Char as Char
import qualified Data.Text as Text
import           Data.Vector.Vector2 (Vector2(..))
import qualified GUI.Momentu.Align as Align
import qualified GUI.Momentu.Animation as Anim
import           GUI.Momentu.Animation.Id (augmentId)
import qualified GUI.Momentu.Element as Element
import           GUI.Momentu.EventMap (EventMap)
import qualified GUI.Momentu.EventMap as E
import           GUI.Momentu.Glue ((/-/), (/|/))
import           GUI.Momentu.Responsive (Responsive)
import qualified GUI.Momentu.Responsive as Responsive
import qualified GUI.Momentu.State as GuiState
import           GUI.Momentu.View (View)
import qualified GUI.Momentu.View as View
import qualified GUI.Momentu.Widget as Widget
import qualified GUI.Momentu.Widgets.Menu as Menu
import qualified GUI.Momentu.Widgets.Menu.Search as SearchMenu
import qualified GUI.Momentu.Widgets.Spacer as Spacer
import qualified GUI.Momentu.Widgets.TextView as TextView
import           Lamdu.Config (HasConfig)
import qualified Lamdu.Config as Config
import qualified Lamdu.Config.Theme as Theme
import           Lamdu.Config.Theme.TextColors (TextColors)
import qualified Lamdu.Config.Theme.TextColors as TextColors
import qualified Lamdu.GUI.ExpressionEdit.TagEdit as TagEdit
import           Lamdu.GUI.ExpressionGui (ExpressionGui)
import qualified Lamdu.GUI.ExpressionGui as ExprGui
import           Lamdu.GUI.ExpressionGui.Monad (ExprGuiM)
import qualified Lamdu.GUI.ExpressionGui.Monad as ExprGuiM
import           Lamdu.GUI.ExpressionGui.Wrap (stdWrap, stdWrapParentExpr)
import qualified Lamdu.GUI.Styled as Styled
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import           Lamdu.Name (Name(..))
import qualified Lamdu.Sugar.Types as Sugar

import           Lamdu.Prelude

doc :: E.Subtitle -> E.Doc
doc text = E.Doc ["Edit", "Record", text]

addFieldId :: Widget.Id -> Widget.Id
addFieldId = (`Widget.joinId` ["add field"])

mkAddFieldEventMap ::
    (MonadReader env m, HasConfig env, Applicative o) =>
    Widget.Id -> m (EventMap (o GuiState.Update))
mkAddFieldEventMap myId =
    Lens.view (Config.config . Config.recordAddFieldKeys)
    <&>
    \keys ->
    addFieldId myId
    & pure
    & E.keysEventMapMovesCursor keys (doc "Add Field")

addFieldWithSearchTermEventMap :: Applicative o => Widget.Id -> EventMap (o GuiState.Update)
addFieldWithSearchTermEventMap myId =
    E.charEventMap "Character" (doc "Add Field") f
    where
        f c
            | Char.isAlpha c =
                addFieldId myId
                & SearchMenu.enterWithSearchTerm (Text.singleton c)
                & pure
                & Just
            | otherwise = Nothing

makeUnit ::
    (Monad i, Monad o) =>
    Sugar.Payload (Name o) i o ExprGui.Payload ->
    ExprGuiM i o (Responsive (o GuiState.Update))
makeUnit pl =
    do
        makeFocusable <- Widget.makeFocusableView ?? myId <&> (Align.tValue %~)
        addFieldEventMap <- mkAddFieldEventMap myId
        stdWrap pl
            <*> ( (/|/) <$> Styled.grammarLabel "{" <*> Styled.grammarLabel "}"
                    <&> makeFocusable
                    <&> Align.tValue %~ Widget.weakerEvents
                        (addFieldEventMap <> addFieldWithSearchTermEventMap myId)
                    <&> Responsive.fromWithTextPos
                )
    where
        myId = WidgetIds.fromExprPayload pl

make ::
    (Monad i, Monad o) =>
    Sugar.Composite (Name o) i o (ExprGui.SugarExpr i o) ->
    Sugar.Payload (Name o) i o ExprGui.Payload ->
    ExprGuiM i o (ExpressionGui o)
make (Sugar.Composite [] Sugar.ClosedComposite{} addField) pl =
    -- Ignore the ClosedComposite actions - it only has the open
    -- action which is equivalent ot deletion on the unit record
    do
        isAddField <- GuiState.isSubCursor ?? addFieldId (WidgetIds.fromExprPayload pl)
        if isAddField
            then
                stdWrapParentExpr pl
                <*> (makeAddFieldRow addField pl <&> (:[]) >>= makeRecord pure)
            else makeUnit pl
make (Sugar.Composite fields recordTail addField) pl =
    do
        addFieldEventMap <- mkAddFieldEventMap (WidgetIds.fromExprPayload pl)
        tailEventMap <-
            case recordTail of
            Sugar.ClosedComposite actions ->
                closedRecordEventMap actions
            Sugar.OpenComposite actions restExpr ->
                openRecordEventMap actions restExpr
        fieldGuis <- mapM makeFieldRow fields
        isAddField <- GuiState.isSubCursor ?? addFieldId (WidgetIds.fromExprPayload pl)
        addFieldGuis <-
            if isAddField
            then makeAddFieldRow addField pl <&> (:[])
            else pure []
        stdWrapParentExpr pl
            <*> (makeRecord postProcess (fieldGuis ++ addFieldGuis) <&> Widget.weakerEvents goToRecordEventMap)
            <&> Widget.weakerEvents (addFieldEventMap <> tailEventMap)
    where
        postProcess =
            case recordTail of
            Sugar.OpenComposite actions restExpr ->
                makeOpenRecord actions restExpr
            _ -> pure
        goToRecordEventMap =
            WidgetIds.fromExprPayload pl & GuiState.updateCursor & pure & const
            & E.charGroup Nothing (E.Doc ["Navigation", "Go to parent"]) "}"

makeRecord ::
    ( MonadReader env m, Theme.HasTheme env, Element.HasAnimIdPrefix env, Spacer.HasStdSpacing env
    , Functor o
    ) =>
    (Responsive (o GuiState.Update) -> m (Responsive (o GuiState.Update))) ->
    [Responsive.TaggedItem (o GuiState.Update)] ->
    m (Responsive (o GuiState.Update))
makeRecord _ [] = error "makeRecord with no fields"
makeRecord postProcess fieldGuis =
    Styled.addValFrame <*>
    do
        opener <- Styled.grammarLabel "{"
        Responsive.taggedList
            <*> addPostTags fieldGuis
            >>= postProcess
            <&> (opener /|/)

addPostTags ::
    (MonadReader env m, Theme.HasTheme env, TextView.HasStyle env, Element.HasAnimIdPrefix env) =>
    [Responsive.TaggedItem (o GuiState.Update)] -> m [Responsive.TaggedItem (o GuiState.Update)]
addPostTags items =
    items
    & zipWith f [0 :: Int ..]
    & sequenceA
    where
        f idx item =
            Styled.grammarLabel txt
            & Reader.local (Element.animIdPrefix %~ augmentId idx)
            <&> \label -> item & Responsive.tagPost .~ (label <&> Widget.fromView)
            where
                txt | idx < lastIdx = ","
                    | otherwise = "}"
        lastIdx = length items - 1

makeAddFieldRow ::
    (Monad i, Monad o) =>
    Sugar.TagSelection (Name o) i o Sugar.EntityId ->
    Sugar.Payload name i o ExprGui.Payload ->
    ExprGuiM i o (Responsive.TaggedItem (o GuiState.Update))
makeAddFieldRow addField pl =
    TagEdit.makeTagHoleEdit addField mkPickResult tagHoleId
    & Styled.withColor TextColors.recordTagColor
    <&>
    \tagHole ->
    Responsive.TaggedItem
    { Responsive._tagPre = tagHole
    , Responsive._taggedItem = Element.empty
    , Responsive._tagPost = Element.empty
    }
    where
        tagHoleId = addFieldId (WidgetIds.fromExprPayload pl)
        mkPickResult _ dst =
            Menu.PickResult
            { Menu._pickDest = WidgetIds.fromEntityId dst
            , Menu._pickNextEntryPoint = WidgetIds.fromEntityId dst
            }

makeFieldRow ::
    (Monad i, Monad o) =>
    Sugar.CompositeItem (Name o) i o (ExprGui.SugarExpr i o) ->
    ExprGuiM i o (Responsive.TaggedItem (o GuiState.Update))
makeFieldRow (Sugar.CompositeItem delete tag fieldExpr) =
    do
        itemEventMap <- recordDelEventMap delete
        tagLabel <-
            TagEdit.makeRecordTag (ExprGui.nextHolesBefore fieldExpr) tag
            <&> Align.tValue %~ Widget.weakerEvents itemEventMap
        hspace <- Spacer.stdHSpace
        fieldGui <- ExprGuiM.makeSubexpression fieldExpr
        pure Responsive.TaggedItem
            { Responsive._tagPre = tagLabel /|/ hspace
            , Responsive._taggedItem = Widget.weakerEvents itemEventMap fieldGui
            , Responsive._tagPost = Element.empty
            }

separationBar :: TextColors -> Widget.R -> Anim.AnimId -> View
separationBar theme width animId =
    View.unitSquare (animId <> ["tailsep"])
    & Element.tint (theme ^. TextColors.recordTailColor)
    & Element.scale (Vector2 width 10)

makeOpenRecord ::
    (Monad i, Monad o) =>
    Sugar.OpenCompositeActions o -> ExprGui.SugarExpr i o ->
    ExpressionGui o -> ExprGuiM i o (ExpressionGui o)
makeOpenRecord (Sugar.OpenCompositeActions close) rest fieldsGui =
    do
        theme <- Lens.view Theme.theme
        vspace <- Spacer.stdVSpace
        restExpr <- Styled.addValPadding <*> ExprGuiM.makeSubexpression rest
        config <- Lens.view Config.config
        let restEventMap =
                close <&> WidgetIds.fromEntityId
                & E.keysEventMapMovesCursor (Config.delKeys config) (doc "Close")
        animId <- Lens.view Element.animIdPrefix
        let layout layoutMode fields =
                fields
                /-/
                separationBar (theme ^. Theme.textColors) (max minWidth targetWidth) animId
                /-/
                vspace
                /-/
                restW
                where
                    restW =
                        (restExpr ^. Responsive.render) layoutMode
                        <&> Widget.weakerEvents restEventMap
                    minWidth = restW ^. Element.width
                    targetWidth = fields ^. Element.width
        fieldsGui & Responsive.render . Lens.imapped %@~ layout & pure

openRecordEventMap ::
    (MonadReader env m, HasConfig env, Functor o) =>
    Sugar.OpenCompositeActions o ->
    Sugar.Expression name i o a ->
    m (EventMap (o GuiState.Update))
openRecordEventMap (Sugar.OpenCompositeActions close) restExpr
    | isHole restExpr =
        Lens.view (Config.config . Config.recordCloseKeys)
        <&>
        \keys ->
        close <&> WidgetIds.fromEntityId
        & E.keysEventMapMovesCursor keys (doc "Close")
    | otherwise = pure mempty
    where
        isHole = Lens.has (Sugar.rBody . Sugar._BodyHole)

closedRecordEventMap ::
    (MonadReader env m, HasConfig env, Functor o) =>
    Sugar.ClosedCompositeActions o -> m (EventMap (o GuiState.Update))
closedRecordEventMap (Sugar.ClosedCompositeActions open) =
    Lens.view (Config.config . Config.recordOpenKeys)
    <&>
    \keys ->
    open <&> WidgetIds.fromEntityId
    & E.keysEventMapMovesCursor keys (doc "Open")

recordDelEventMap ::
    (MonadReader env m, HasConfig env, Functor o) =>
    o Sugar.EntityId -> m (EventMap (o GuiState.Update))
recordDelEventMap delete =
    Lens.view Config.config <&> Config.delKeys
    <&>
    \keys ->
    delete <&> WidgetIds.fromEntityId
    & E.keysEventMapMovesCursor keys (doc "Delete Field")
