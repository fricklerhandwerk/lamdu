{-# LANGUAGE TemplateHaskell, PatternGuards, NoImplicitPrelude, FlexibleContexts, OverloadedStrings, TypeFamilies, DeriveTraversable #-}
-- | The search area (search term + results) of an open/active hole.

module Lamdu.GUI.ExpressionEdit.HoleEdit.Open
    ( makeOpenSearchAreaGui
    ) where

import qualified Control.Lens as Lens
import qualified Control.Monad.Reader as Reader
import           Control.Monad.Transaction (MonadTransaction(..))
import           Data.List.Lens (suffixed)
import qualified Data.Map as Map
import qualified Data.Monoid as Monoid
import           Data.Store.Property (Property)
import qualified Data.Store.Property as Property
import           Data.Store.Transaction (Transaction)
import qualified Data.Text as Text
import           GUI.Momentu (Widget, EventResult, AnimId)
import           GUI.Momentu.Align (Aligned(..), WithTextPos(..))
import qualified GUI.Momentu.Align as Align
import qualified GUI.Momentu.Animation as Anim
import qualified GUI.Momentu.Element as Element
import qualified GUI.Momentu.EventMap as E
import           GUI.Momentu.Glue ((/-/), (/|/))
import qualified GUI.Momentu.Hover as Hover
import qualified GUI.Momentu.MetaKey as MetaKey
import           GUI.Momentu.Rect (Rect(..))
import qualified GUI.Momentu.Responsive as Responsive
import qualified GUI.Momentu.Widget as Widget
import qualified GUI.Momentu.Widget.Id as WidgetId
import qualified GUI.Momentu.Widgets.Grid as Grid
import qualified GUI.Momentu.Widgets.Menu as Menu
import qualified GUI.Momentu.Widgets.Spacer as Spacer
import qualified Lamdu.CharClassification as Chars
import           Lamdu.Config (Config)
import qualified Lamdu.Config as Config
import qualified Lamdu.Config.Theme as Theme
import qualified Lamdu.GUI.ExpressionEdit.HoleEdit.EventMap as EventMap
import           Lamdu.GUI.ExpressionEdit.HoleEdit.ResultGroups (ResultsList(..), Result(..))
import qualified Lamdu.GUI.ExpressionEdit.HoleEdit.ResultGroups as HoleResults
import qualified Lamdu.GUI.ExpressionEdit.HoleEdit.SearchTerm as SearchTerm
import qualified Lamdu.GUI.ExpressionEdit.HoleEdit.State as HoleState
import           Lamdu.GUI.ExpressionEdit.HoleEdit.WidgetIds (WidgetIds(..))
import           Lamdu.GUI.ExpressionGui (ExpressionGui)
import qualified Lamdu.GUI.ExpressionGui as ExpressionGui
import           Lamdu.GUI.ExpressionGui.Monad (ExprGuiM)
import qualified Lamdu.GUI.ExpressionGui.Monad as ExprGuiM
import           Lamdu.GUI.ExpressionGui.Types (ExpressionN)
import qualified Lamdu.GUI.ExpressionGui.Types as ExprGuiT
import qualified Lamdu.GUI.TypeView as TypeView
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import           Lamdu.Name (Name(..))
import qualified Lamdu.Sugar.Lens as SugarLens
import qualified Lamdu.Sugar.NearestHoles as NearestHoles
import qualified Lamdu.Sugar.Parens as AddParens
import qualified Lamdu.Sugar.Types as Sugar

import           Lamdu.Prelude

type T = Transaction

data PickedResult = PickedResult
    { _pickedEventResult :: Widget.EventResult
    , _pickedIdTranslations :: Widget.Id -> Widget.Id
    }
Lens.makeLenses ''PickedResult

resultSuffix :: Lens.Prism' AnimId AnimId
resultSuffix = suffixed ["result suffix"]

data ResultGroup m = ResultGroup
    { _rgOption :: !(Menu.Option (ExprGuiM m) (T m Widget.EventResult))
    , _rgPickEventMap :: !(Widget.EventMap (T m Widget.EventResult))
    }
Lens.makeLenses ''ResultGroup

makeShownResult ::
    Monad m =>
    Sugar.Payload f ExprGuiT.Payload -> Property (T m) Text -> Result m ->
    ExprGuiM m
    ( Widget.EventMap (T m Widget.EventResult)
    , WithTextPos (Widget (T m Widget.EventResult))
    )
makeShownResult pl stateProp result =
    do
        -- Warning: rHoleResult should be ran at most once!
        -- Running it more than once caused a horrible bug (bugfix: 848b6c4407)
        res <- rHoleResult result & transaction
        theme <- Theme.hole <$> Lens.view Theme.theme
        stdSpacing <- Spacer.getSpaceSize
        let padding = Theme.holeResultPadding theme <&> realToFrac & (* stdSpacing)
        makeHoleResultWidget pl stateProp (rId result) res <&> _2 %~ Element.pad padding

makeResultGroup ::
    Monad m =>
    Sugar.Payload f ExprGuiT.Payload -> Property (T m) Text ->
    ResultsList m ->
    ExprGuiM m (ResultGroup m)
makeResultGroup pl stateProp results =
    do
        (pickMain, mainResultWidget) <- makeShownResult pl stateProp mainResult
        return ResultGroup
            { _rgOption = Menu.Option
                { Menu._oId = results ^. HoleResults.rlExtraResultsPrefixId
                , Menu._oWidget = mainResultWidget
                , Menu._oSubmenuWidgets =
                    if null extras
                    then Menu.SubmenuEmpty
                    else Menu.SubmenuItems (traverse (makeShownResult pl stateProp) extras <&> map snd)
                }
            , _rgPickEventMap = pickMain
            }
    where
        extras = results ^. HoleResults.rlExtra
        mainResult = results ^. HoleResults.rlMain

applyResultLayout ::
    Functor f => f (ExpressionGui m) -> f (WithTextPos (Widget (T m Widget.EventResult)))
applyResultLayout fGui =
    fGui <&> (^. Responsive.render)
    ?? Responsive.LayoutParams
        { Responsive._layoutMode = Responsive.LayoutWide
        , Responsive._layoutContext = Responsive.LayoutClear
        }

eventResultOfPickedResult :: Sugar.PickedResult -> PickedResult
eventResultOfPickedResult pr =
    PickedResult
    { _pickedEventResult =
        Widget.EventResult
        { Widget._eCursor = Monoid.Last Nothing
        , Widget._eAnimIdMapping =
            Monoid.Endo $ pickedResultAnimIdTranslation $ pr ^. Sugar.prIdTranslation
        , Widget._eVirtualCursor = Monoid.Last Nothing
        }
    , _pickedIdTranslations =
        pr ^. Sugar.prIdTranslation
        & Lens.mapped . Lens.both %~ WidgetIds.fromEntityId
        & mapPrefix
    }
    where
        mapPrefix = foldr ((.) . reprefix) id
        reprefix (old, new) ident =
            WidgetId.subId old ident & maybe ident (WidgetId.joinId new)
        pickedResultAnimIdTranslation idTranslations =
            -- Map only the first anim id component
            Lens.ix 0 %~ \x -> fromMaybe x $ Map.lookup x idMap
            where
                idMap =
                    idTranslations
                    & Lens.traversed . Lens.both %~
                      head . Widget.toAnimId . WidgetIds.fromEntityId
                    & Map.fromList

afterPick ::
    Monad m =>
    Property (T m) Text -> Sugar.EntityId ->
    Widget.Id -> Maybe Widget.Id ->
    Sugar.PickedResult -> T m PickedResult
afterPick stateProp holeId resultId mFirstHoleInside pr =
    do
        Property.set stateProp mempty
        result
            & pickedEventResult . Widget.eCursor .~ Monoid.Last (Just cursorId)
            & pickedEventResult . Widget.eAnimIdMapping %~
                mappend (Monoid.Endo obliterateOtherResults)
            & return
    where
        result = eventResultOfPickedResult pr
        cursorId =
            mFirstHoleInside
            & fromMaybe myHoleId
            & result ^. pickedIdTranslations
        myHoleId = WidgetIds.fromEntityId holeId
        obliterateOtherResults animId =
            animId ^? resultSuffix . suffixed (Widget.toAnimId resultId)
            & fromMaybe animId

-- | Remove unwanted event handlers from a hole result
removeUnwanted :: Config -> Widget.EventMap a -> Widget.EventMap a
removeUnwanted config =
    E.deleteKeys unwantedKeyEvents
    where
        unwantedKeyEvents =
            concat
            [ Config.delKeys config
            , Config.enterSubexpressionKeys config
            , Config.leaveSubexpressionKeys config
            , Grid.stdKeys ^.. Lens.folded
            , Config.letAddItemKeys config
            ]
            <&> MetaKey.toModKey
            <&> E.KeyEvent MetaKey.KeyState'Pressed

fixNumWithDotEventMap ::
    Monad m =>
    Text -> Sugar.HoleResult (T m) (Sugar.Expression name (T m) ()) ->
    Widget.EventMap (T m Widget.EventResult)
fixNumWithDotEventMap searchTerm res
    | endsWithDot
    , Lens.has literalNum conv
    , Sugar.WrapAction wrap <- conv ^. hrWrapAction = mkAction wrap
    | endsWithDot
    , Lens.has (wrappedExpr . literalNum) conv
    , Sugar.WrapperAlready t <- conv ^. hrWrapAction = mkAction (return t)
    | otherwise = mempty
    where
        mkAction toHole =
            E.charGroup "Operator" doc Chars.operator $
            \c ->
            do
                (uuid, entityId) <- toHole
                cursor <-
                    HoleState.setHoleStateAndJump uuid
                    ("." <> Text.singleton c) entityId
                return $ Widget.eventResultFromCursor cursor
        endsWithDot = "." `Text.isSuffixOf` searchTerm
        doc = E.Doc ["Edit", "Apply Operator"]
        conv = res ^. Sugar.holeResultConverted
        literalNum = Sugar.rBody . Sugar._BodyLiteral . Sugar._LiteralNum
        wrappedExpr =
            Sugar.rBody . Sugar._BodyHole .
            Sugar.holeKind . Sugar._WrapperHole . Sugar.haExpr
        hrWrapAction = Sugar.rPayload . Sugar.plActions . Sugar.wrap

makeHoleResultWidget ::
    Monad m =>
    Sugar.Payload f ExprGuiT.Payload -> Property (T m) Text ->
    Widget.Id ->
    Sugar.HoleResult (T m) (Sugar.Expression (Name (T m)) (T m) ()) ->
    ExprGuiM m
    ( Widget.EventMap (T m Widget.EventResult)
    , WithTextPos (Widget (T m Widget.EventResult))
    )
makeHoleResultWidget pl stateProp resultId holeResult =
    do
        config <- Lens.view Config.config
        let holeConfig = Config.hole config
        let pickAndMoveToNextHole =
                Widget.keysEventMapMovesCursor (Config.holePickAndMoveToNextHoleKeys holeConfig)
                    (E.Doc ["Edit", "Result", "Pick and move to next hole"]) .
                pure . WidgetIds.fromEntityId
        let pickEventMap =
                -- TODO: Does this entityId business make sense?
                case pl ^. Sugar.plData . ExprGuiT.plNearestHoles . NearestHoles.next of
                Just nextHoleEntityId | Lens.has Lens._Nothing mFirstHoleInside ->
                    simplePickRes (Config.holePickResultKeys holeConfig) <>
                    pickAndMoveToNextHole nextHoleEntityId
                _ ->
                    simplePickRes (mappend Config.holePickResultKeys Config.holePickAndMoveToNextHoleKeys holeConfig)
                <&> pickBefore
        isSelected <- Widget.isSubCursor ?? resultId
        when isSelected (ExprGuiM.setResultPicker (pickBefore (pure mempty)))
        holeResultConverted
            & postProcessSugar (pl ^. Sugar.plData . ExprGuiT.plMinOpPrec)
            & ExprGuiM.makeSubexpression
            <&> Widget.enterResultCursor .~ resultId
            <&> E.eventMap %~ removeUnwanted config
            <&> E.eventMap %~ mappend (fixNumWithDotEventMap searchTerm holeResult)
            <&> E.eventMap . E.emDocs . E.docStrs . Lens._last %~ (<> " (On picked result)")
            <&> E.eventMap . Lens.mapped %~ pickBefore
            <&> E.eventMap %~ mappend pickEventMap
            & Widget.assignCursor resultId idWithinResultWidget
            & applyResultLayout
            <&> fixFocalArea
            <&> Element.setLayers . Element.layers . Lens.traverse %~
                Anim.mapIdentities (<> (resultSuffix # Widget.toAnimId resultId))
            <&> (,) pickEventMap
    where
        searchTerm = stateProp ^. Property.pVal
        fixFocalArea =
            Align.tValue . Widget.sizedState <. Widget._StateFocused . Lens.mapped . Widget.fFocalAreas .@~
            (:[]) . Rect 0
        holeResultId =
            holeResultConverted ^. Sugar.rPayload . Sugar.plEntityId
            & WidgetIds.fromEntityId
        mFirstHoleInside =
            holeResult ^?
            Sugar.holeResultConverted . SugarLens.holePayloads . Sugar.plEntityId
            <&> WidgetIds.fromEntityId
        idWithinResultWidget = fromMaybe holeResultId mFirstHoleInside
        holeResultConverted = holeResult ^. Sugar.holeResultConverted
        pickBefore action =
            do
                pickedResult <-
                    holeResult ^. Sugar.holeResultPick
                    >>= afterPick stateProp (pl ^. Sugar.plEntityId) resultId mFirstHoleInside
                action
                    <&> Widget.eCursor . Lens._Wrapped' . Lens.mapped %~
                        pickedResult ^. pickedIdTranslations
                    <&> mappend (pickedResult ^. pickedEventResult)
        simplePickRes keys =
            Widget.keysEventMap keys (E.Doc ["Edit", "Result", "Pick"]) (return ())

postProcessSugar :: Int -> ExpressionN m () -> ExpressionN m ExprGuiT.Payload
postProcessSugar minOpPrec expr =
    expr
    & AddParens.addWith minOpPrec
    <&> pl
    & SugarLens.holeArgs . Sugar.plData . ExprGuiT.plShowAnnotation
    .~ ExprGuiT.alwaysShowAnnotations
    where
        pl (x, needParens, ()) =
            ExprGuiT.Payload
            { ExprGuiT._plStoredEntityIds = []
            , ExprGuiT._plNearestHoles = NearestHoles.none
            , ExprGuiT._plShowAnnotation = ExprGuiT.neverShowAnnotations
            , ExprGuiT._plNeedParens = needParens == AddParens.NeedsParens
            , ExprGuiT._plMinOpPrec = x
            }

emptyPickEventMap ::
    (Monad m, Applicative f) => ExprGuiM m (Widget.EventMap (f Widget.EventResult))
emptyPickEventMap =
    Lens.view Config.config <&> Config.hole <&> keys <&> mkEventMap
    where
        keys c = Config.holePickResultKeys c ++ Config.holePickAndMoveToNextHoleKeys c
        mkEventMap k =
            Widget.keysEventMap k (E.Doc ["Edit", "Result", "Pick (N/A)"]) (pure ())

makeResultsWidget ::
    Monad m =>
    Widget.R -> Sugar.Payload f ExprGuiT.Payload -> Property (T m) Text ->
    [ResultsList m] -> Menu.HasMoreOptions ->
    ExprGuiM m (Widget.EventMap (T m Widget.EventResult), Hover.Ordered (Widget (T m Widget.EventResult)))
makeResultsWidget minWidth pl stateProp shownResultsLists hiddenResults =
    do
        groupsWidgets <- traverse (makeResultGroup pl stateProp) shownResultsLists
        pickResultEventMap <-
            case groupsWidgets of
            [] -> emptyPickEventMap
            (x:_) -> x ^. rgPickEventMap & return
        Menu.layout minWidth (groupsWidgets <&> (^. rgOption)) hiddenResults
            <&> (,) pickResultEventMap

assignHoleEditCursor ::
    Monad m =>
    WidgetIds -> Text -> [Widget.Id] -> [Widget.Id] ->
    ExprGuiM m a ->
    ExprGuiM m a
assignHoleEditCursor widgetIds searchTerm shownMainResultsIds allShownResultIds action =
    do
        shouldBeOnResult <- sub (hidResultsPrefix widgetIds)
        isOnResult <- traverse sub allShownResultIds <&> or
        let assignSource
                | shouldBeOnResult && not isOnResult =
                      Reader.local (Widget.cursor .~ destId)
                | otherwise =
                      Widget.assignCursor (hidOpen widgetIds) destId
        assignSource action
    where
        searchTermId = hidOpenSearchTerm widgetIds
        sub x = Widget.isSubCursor ?? x
        destId
            | Text.null searchTerm = searchTermId
            | otherwise = head (shownMainResultsIds ++ [searchTermId])

resultsHoverOptions ::
    ( MonadReader env m, Hover.HasStyle env, Element.HasAnimIdPrefix env
    , Functor f
    ) =>
    m
    (Menu.Placement ->
     (Widget (f EventResult) -> Widget (f EventResult)) ->
     Hover.Ordered (Widget (f EventResult)) ->
     Hover.AnchoredWidget (f EventResult) ->
     [Hover.AnchoredWidget (f EventResult)])
resultsHoverOptions =
    Hover.hover <&> \hover pos addAnnotation results searchTerm ->
    let resultsAbove alignment =
            results ^. Hover.backward & hover & Aligned alignment
        annotatedTerm alignment =
            searchTerm & Widget.widget %~ addAnnotation & Aligned alignment
        aboveRight = resultsAbove 0 /-/ annotatedTerm 0
        aboveLeft =
            resultsAbove 1
            /-/ annotatedTerm 1
        annotatedResultsBelow = results ^. Hover.forward & addAnnotation & hover
        resultsBelow = results ^. Hover.forward & hover
        belowRight =
            Aligned 0 searchTerm
            /-/
            Aligned 0 annotatedResultsBelow
        belowLeft =
            Aligned 1 searchTerm
            /-/
            Aligned 1 annotatedResultsBelow
        centerRight = annotatedTerm 0.5 /|/ Aligned 0.5 resultsBelow
        rightAbove = annotatedTerm 1 /|/ resultsAbove 1
        leftAbove = resultsAbove 1 /|/ annotatedTerm 1
    in  case pos of
        Menu.Above ->
            [ aboveRight
            , aboveLeft
            ]
        Menu.AnyPlace ->
            [ belowRight
            , aboveRight
            , belowLeft
            , aboveLeft
            , centerRight
            ]
        Menu.Below ->
            [ belowRight
            , belowLeft
            , rightAbove
            , leftAbove
            ]
        <&> (^. Align.value)

makeUnderCursorAssignment ::
    Monad m =>
    [ResultsList m] -> Menu.HasMoreOptions ->
    Sugar.Hole (T m) (ExpressionN m ()) (ExprGuiT.SugarExpr m) ->
    Sugar.Payload (T m) ExprGuiT.Payload ->
    Property (T m) Text ->
    WidgetIds ->
    ExprGuiM m (Menu.Placement -> WithTextPos (Widget (T m Widget.EventResult)))
makeUnderCursorAssignment shownResultsLists hasHiddenResults hole pl stateProp widgetIds =
    do
        -- We make our own type view here instead of
        -- ExpressionGui.stdWrap, because we want to synchronize the
        -- active BG width with the inferred type width
        typeView <-
            ExpressionGui.addAnnotationBackground holeAnimId
            <*> TypeView.make (pl ^. Sugar.plAnnotation . Sugar.aInferredType) holeAnimId
            <&> (^. Align.tValue)

        searchTermEventMap <-
            EventMap.makeOpenEventMap holeKind stateProp <&> disallowFirstOperatorChar

        (pickFirstResult, resultsWidgets) <-
            makeResultsWidget (typeView ^. Element.width) pl stateProp
            shownResultsLists hasHiddenResults
            <&> _2 . Lens.mapped %~ E.strongerEvents searchTermEventMap

        vspace <- ExpressionGui.annotationSpacer
        let addAnnotation x = x /-/ vspace /-/ typeView
        searchTermWidget <-
            SearchTerm.make widgetIds holeKind stateProp
            <&> Align.tValue %~ Hover.anchor . E.weakerEvents (pickFirstResult <> blockOperatorEvents)
        mkOptions <-
            resultsHoverOptions
            & Reader.local (Element.animIdPrefix .~ WidgetId.toAnimId (hidOpen widgetIds))
        return $
            \placement ->
            searchTermWidget
            & Align.tValue %~
                Hover.hoverInPlaceOf
                (mkOptions placement addAnnotation resultsWidgets
                    (searchTermWidget ^. Align.tValue))
    where
        holeKind = hole ^. Sugar.holeKind
        blockOperatorEvents
            | Text.null searchTerm || Text.all (`elem` Chars.operator) searchTerm = mempty
            | otherwise =
                E.charGroup "Operator" (E.Doc ["Edit", "Apply operator (blocked)"])
                Chars.operator mempty
        holeAnimId = hidHole widgetIds & Widget.toAnimId
        disallowFirstOperatorChar
            | Text.null searchTerm = E.filterChars (`notElem` Chars.operator)
            | otherwise = id
        searchTerm = stateProp ^. Property.pVal

makeOpenSearchAreaGui ::
    Monad m =>
    Sugar.Hole (T m) (ExpressionN m ()) (ExprGuiT.SugarExpr m) ->
    Sugar.Payload (T m) ExprGuiT.Payload ->
    Property (T m) Text ->
    WidgetIds ->
    ExprGuiM m (Menu.Placement -> WithTextPos (Widget (T m Widget.EventResult)))
makeOpenSearchAreaGui hole pl stateProp widgetIds =
    do
        (shownResultsLists, hasHiddenResults) <- HoleResults.makeAll hole searchTerm widgetIds
        let shownMainResultsIds = shownResultsLists <&> rId . (^. HoleResults.rlMain)
        let allShownResultIds =
                [ rId . (^. HoleResults.rlMain)
                , (^. HoleResults.rlExtraResultsPrefixId)
                ] <*> shownResultsLists
        delKeys <- Config.delKeys
        let unwrapAsDelEventMap =
                hole ^? Sugar.holeKind . Sugar._WrapperHole . Sugar.haUnwrap . Sugar._UnwrapAction
                & maybe mempty
                    ( Widget.keysEventMapMovesCursor delKeys
                        (E.Doc ["Edit", "Unwrap"])
                        . fmap WidgetIds.fromEntityId
                    )
        makeUnderCursorAssignment shownResultsLists
            hasHiddenResults hole pl stateProp widgetIds
            & assignHoleEditCursor widgetIds searchTerm shownMainResultsIds allShownResultIds
            <&> Lens.mapped . Align.tValue %~ E.weakerEvents unwrapAsDelEventMap
    where
        searchTerm = stateProp ^. Property.pVal
