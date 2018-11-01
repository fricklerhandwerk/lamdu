-- | A main-loop that draws DrawingCombinator images and reacts to GLFW events,
-- given a Handlers record from the user.
--
-- The higher level GUI.Momentu.MainLoop builds upon this main-loop.

module GUI.Momentu.Main.Image
    ( mainLoop
    , PerfCounters(..)
    , TickResult(..)
    , Handlers(..)
    , EventLoop.wakeUp
    ) where

import           Data.IORef
import           Data.Vector.Vector2 (Vector2(..))
import           GUI.Momentu.Animation (Size)
import qualified GUI.Momentu.Draw.FPS as FPS
import           GUI.Momentu.Font (Font)
import           GUI.Momentu.Main.Events.Loop (Event, Next(..), eventLoop)
import qualified GUI.Momentu.Main.Events.Loop as EventLoop
import qualified Graphics.DrawingCombinators.Extended as Draw
import           Graphics.Rendering.OpenGL.GL (($=))
import qualified Graphics.Rendering.OpenGL.GL as GL
import qualified Graphics.UI.GLFW as GLFW
import qualified Graphics.UI.GLFW.Utils as GLFW.Utils
import qualified System.Info as SysInfo
import           System.TimeIt (timeItT)

import           Lamdu.Prelude

data PerfCounters = PerfCounters
    { renderTime :: Double
    , swapBuffersTime :: Double
    }

data TickResult
    = StopTicking               -- | Stop ticking until we have more events
    | TickImage (Draw.Image ()) -- | Here's the next image, tick again please

data Handlers = Handlers
    { eventHandler :: Event -> IO Bool
        -- ^ Handle a single event, return whether event was handled or ignored
    , tick :: IO TickResult
        -- ^ A tick passed since we had an image update, yield the next image or stop
    , refresh :: IO (Draw.Image ())
        -- ^ Window redraw requested, please provide an image to draw
    , fpsFont :: IO (Maybe Font)
    , reportPerfCounters :: PerfCounters -> IO ()
    }

data EventResult = ERNone | ERRefresh | ERQuit deriving (Eq, Ord, Show)
instance Semigroup EventResult where
    (<>) = max
instance Monoid EventResult where
    mempty = ERNone
    mappend = (<>)

glDraw :: GLFW.Window -> Vector2 Double -> Draw.Image a -> IO PerfCounters
glDraw win (Vector2 winSizeX winSizeY) image =
    do
        GL.viewport $=
            (GL.Position 0 0,
             GL.Size (round winSizeX) (round winSizeY))
        GL.matrixMode $= GL.Projection
        GL.loadIdentity
        GL.ortho 0 winSizeX winSizeY 0 (-1) 1
        (timedRender, ()) <-
            do
                Draw.clearRender image
                platformWorkarounds
            & timeItT
        (timedSwapBuffers, ()) <- timeItT (GLFW.swapBuffers win)
        pure PerfCounters
            { renderTime = timedRender
            , swapBuffersTime = timedSwapBuffers
            }
    where
        platformWorkarounds
            | SysInfo.os == "darwin" =
                do
                    -- Work around for https://github.com/glfw/glfw/issues/1334
                    GL.colorMask GL.$= GL.Color4 GL.Disabled GL.Disabled GL.Disabled GL.Enabled
                    GL.clearColor GL.$= GL.Color4 1 1 1 1
                    GL.clear [GL.ColorBuffer]
                    GL.colorMask GL.$= GL.Color4 GL.Enabled GL.Enabled GL.Enabled GL.Enabled
            | otherwise = pure ()

mainLoop :: GLFW.Window -> (Size -> Handlers) -> IO ()
mainLoop win imageHandlers =
    do
        initialSize <- GLFW.Utils.windowSize win
        drawnImageHandlers <- imageHandlers initialSize & newIORef
        fps <- FPS.new
        eventResultRef <- newIORef mempty
        let iteration =
                do
                    winSize <- GLFW.Utils.windowSize win
                    let handlers = imageHandlers winSize
                    writeIORef drawnImageHandlers handlers
                    fpsImg <-
                        fpsFont handlers >>= \case
                        Nothing -> pure mempty
                        Just font -> FPS.update fps >>= FPS.render font win
                    let draw img =
                            NextPoll <$
                            (glDraw win winSize (fpsImg <> img)
                                >>= reportPerfCounters handlers)
                    eventResult <- readIORef eventResultRef
                    writeIORef eventResultRef mempty
                    case eventResult of
                        ERQuit -> pure NextQuit
                        ERRefresh -> refresh handlers >>= draw
                        ERNone ->
                            tick handlers >>=
                            \case
                            StopTicking -> pure NextWait
                            TickImage image -> draw image
        let eventRes = modifyIORef eventResultRef . (<>)
        let handleEvent =
                \case
                EventLoop.EventWindowClose -> True <$ eventRes ERQuit
                EventLoop.EventWindowRefresh -> True <$ eventRes ERRefresh
                EventLoop.EventFramebufferSize {} -> True <$ eventRes ERRefresh
                event ->
                    do
                        handlers <- readIORef drawnImageHandlers
                        eventHandler handlers event
        eventLoop win handleEvent iteration
