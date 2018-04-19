-- Work in progress

{-# LANGUAGE GeneralizedNewtypeDeriving, TypeFamilies #-}

module TestDisambiguation (test) where

import           Control.Monad.Unit (Unit(..))
import           Control.Monad.Trans.FastWriter (Writer, runWriter)
import           Control.Monad.Writer (MonadWriter(..))
import           Data.Functor.Identity (Identity(..))
import           Data.Property (Property(..), MkProperty(..))
import           Data.String (IsString(..))
import qualified Lamdu.Calc.Type as T
import           Lamdu.Name (Name)
import qualified Lamdu.Name as Name
import           Lamdu.Sugar.Names.Add (InternalName(..), addToWorkArea)
import           Lamdu.Sugar.Names.CPS (liftCPS)
import qualified Lamdu.Sugar.Names.Walk as Walk
import qualified Lamdu.Sugar.Types as Sugar
import           Test.Framework (Test, testGroup)
import           Test.Framework.Providers.HUnit (testCase)
import           Test.HUnit (assertString)
import           Test.Lamdu.Instances ()
import qualified Test.Lamdu.SugarStubs as Stub

import           Lamdu.Prelude

newtype CollectNames name a = CollectNames { runCollectNames :: Writer [name] a }
    deriving (Functor, Applicative, Monad, MonadWriter [name])

instance Walk.MonadNaming (CollectNames name) where
    type OldName (CollectNames name) = name
    type NewName (CollectNames name) = name
    type IM (CollectNames name) = Identity
    opGetName _ _ x = x <$ tell [x]
    opWithName _ _ x = x <$ liftCPS (tell [x])
    opRun = pure (pure . fst . runWriter . runCollectNames)

test :: Test
test =
    testGroup "Disambiguation"
    [ testCase "disambiguation(#396)" workArea396
    , testCase "globals collide" workAreaGlobals
    ]

assertNoCollisions :: Name o -> IO ()
assertNoCollisions name =
    case Name.visible name of
    (Name.TagText _ Name.NoCollision, Name.NoCollision) -> pure ()
    (Name.TagText text textCollision, tagCollision) ->
        unwords
        [ "Unexpected collision for name", show text
        , show textCollision, show tagCollision
        ] & assertString

testWorkArea ::
    (Name Unit -> IO b) -> Sugar.WorkArea InternalName Identity Unit a -> IO ()
testWorkArea verifyName inputWorkArea =
    addToWorkArea getNameProp inputWorkArea
    & runIdentity
    & getNames
    & traverse_ verifyName

getNames :: Sugar.WorkArea name Identity o a -> [name]
getNames workArea =
    Walk.toWorkArea workArea
    & runCollectNames
    & runWriter
    & snd

getNameProp :: T.Tag -> MkProperty Identity Unit Text
getNameProp tag =
    Property (fromString (show tag)) (const Unit)
    & Identity & MkProperty

--- test inputs:

workArea396 :: IO ()
workArea396 =
    Sugar.WorkArea
    { Sugar._waRepl = Stub.repl lamExpr
    , Sugar._waPanes =
        [ Stub.binderExpr [("paneVar", "num", Stub.numType)] leafExpr
            & Stub.def lamType "def" "def"
            & Stub.pane
        ]
    , Sugar._waGlobals = pure []
    } & testWorkArea assertNoCollisions
    where
        lamType = Stub.funcType Stub.numType Stub.numType
        leafExpr = Stub.expr Stub.numType Sugar.BodyPlaceHolder
        lamExpr =
            Sugar.BodyLam Sugar.Lambda
            { Sugar._lamMode = Sugar.NormalBinder
            , Sugar._lamBinder = Stub.binderExpr [("lamVar", "num", Stub.numType)] leafExpr
            } & Stub.expr lamType

workAreaGlobals :: IO ()
workAreaGlobals =
    Sugar.WorkArea
    { Sugar._waRepl = Stub.repl trivialExpr
    , Sugar._waPanes =
        -- 2 defs sharing the same tag with different Vars/UUIDs,
        -- should collide with ordinary suffixes
        [ Stub.def Stub.numType "def1" "def" trivialBinder & Stub.pane
        , Stub.def Stub.numType "def2" "def" trivialBinder & Stub.pane
        ]
    , Sugar._waGlobals = pure []
    } & testWorkArea verifyName
    where
        verifyName name =
            case Name.visible name of
            (Name.TagText _ Name.NoCollision, Name.NoCollision) -> pure ()
            (Name.TagText _ Name.NoCollision, Name.Collision _) -> pure ()
            (Name.TagText text textCollision, tagCollision) ->
                unwords
                [ "Unexpected/bad collision for name", show text
                , show textCollision, show tagCollision
                ] & assertString
        trivialBinder = Stub.binderExpr [] trivialExpr
        trivialExpr = Stub.expr Stub.numType Sugar.BodyPlaceHolder
