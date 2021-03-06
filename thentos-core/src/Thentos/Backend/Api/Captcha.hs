{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE KindSignatures        #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE PolyKinds             #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

module Thentos.Backend.Api.Captcha (runFrontendApi, runBackendApi, serveBackendApi, serveFrontendApi) where

import Control.Lens ((&), (%~), (.~))
import Control.Monad.Except (catchError, throwError)
import Control.Monad (when)
import Data.Proxy (Proxy(Proxy))
import Data.String.Conversions (ST, SBS, cs)
import Network.HTTP.Types (methodOptions)
import Network.HTTP.Types.Status (ok200)
import Network.Wai (Application)
import Servant.API (GetHeaders)
import Servant.API.Header (Header)
import Servant.API ((:<|>)((:<|>)), (:>), Post, Capture, ReqBody, JSON)
import Servant.API.ResponseHeaders (Headers, addHeader)
import Servant.Server (HasServer(route), ServerT, Server, serve, enter)
import Servant.Server.Internal (methodRouterHeaders)
import System.Log.Logger (Priority(INFO))

import qualified Servant.Docs as Docs
import qualified Servant.Foreign.Internal as Foreign

import System.Log.Missing (logger)
import Thentos.Action
import Thentos.Action.Types (ActionEnv, MonadQuery, MonadAction)
import Thentos.Backend.Api.Auth
import Thentos.Backend.Api.Docs.Common
import Thentos.Backend.Core
import Thentos.Config
import Thentos.Ends.Types
import Thentos.Types

import qualified Paths_thentos_core__ as Paths (version)


-- * main for frontend interface (called from browsers to generate captchas)

runFrontendApi :: HttpConfig -> ActionEnv -> IO ()
runFrontendApi cfg asg = do
    logStart "ThentosCaptchaFrontend" cfg
    runWarpWithCfg cfg $ serveFrontendApi cfg asg

serveFrontendApi :: HttpConfig -> ActionEnv -> Application
serveFrontendApi cfg astate = addCacheControlHeaders $
    let p = Proxy :: Proxy (RestDocs FrontendApi)
    in serve p (restDocs cfg p :<|> frontendApi astate)

type FrontendApi = ThentosAuth :> ThentosCaptchaFrontend

frontendApi :: ActionEnv -> Server FrontendApi
frontendApi as = \creds -> enter (enterAction () as baseActionErrorToServantErr creds)
                           thentosCaptchaFrontend


-- * main for backend interface (called as service from backends to validate solutions)

runBackendApi :: HttpConfig -> ActionEnv -> IO ()
runBackendApi cfg asg = do
    logStart "ThentosCaptchaBackend" cfg
    runWarpWithCfg cfg $ serveBackendApi cfg asg

serveBackendApi :: HttpConfig -> ActionEnv -> Application
serveBackendApi cfg astate = addCacheControlHeaders $
    let p = Proxy :: Proxy (RestDocs BackendApi)
    in serve p (restDocs cfg p :<|> backendApi astate)

type BackendApi = ThentosAuth :> ThentosCaptchaBackend

backendApi :: ActionEnv -> Server BackendApi
backendApi as = \creds -> enter (enterAction () as baseActionErrorToServantErr creds)
                                thentosCaptchaBackend


-- * helpers

logStart :: String -> HttpConfig -> IO ()
logStart cmd cfg = logger INFO $ concat
    ["running rest api Thentos.Backend.Api.Captcha.", cmd, " on ", show (bindUrl cfg), "."]


-- * captcha

type CaptchaOptionsHeaders =
    '[ Header "Access-Control-Allow-Origin" ST
     , Header "Access-Control-Expose-Headers" ST
     , Header "Access-Control-Max-Age" ST
     , Header "Access-Control-Allow-Credentials" ST
     , Header "Access-Control-Allow-Methods" ST
     , Header "Access-Control-Allow-Headers" ST
     ]

addCaptchaOptionsHeaders :: a -> Headers CaptchaOptionsHeaders a
addCaptchaOptionsHeaders =
       addHeader "*"
     . addHeader "X-Thentos-Captcha-Id"
     . addHeader "900"
     . addHeader "true"
     . addHeader "POST, GET, DELETE, PUT, OPTIONS"
     . addHeader "Origin, Content-Type, Accept, X-User-Path, X-User-Token"

type CaptchaHeaders = Header "X-Thentos-Captcha-Id" CaptchaId ': CaptchaOptionsHeaders

addCaptchaHeaders :: CaptchaId -> a -> Headers CaptchaHeaders a
addCaptchaHeaders cid = addHeader cid . addCaptchaOptionsHeaders

type ThentosCaptchaFrontend =
       "captcha"                             :> Options (Headers CaptchaOptionsHeaders ())
  :<|> "captcha"                             :> Post    '[PNG] (Headers CaptchaHeaders ImageData)
  :<|> "audio_captcha" :> Capture "voice" ST :> Options (Headers CaptchaOptionsHeaders ())
  :<|> "audio_captcha" :> Capture "voice" ST :> Post    '[WAV] (Headers CaptchaHeaders SBS)

type ThentosCaptchaBackend =
       "solve_captcha" :> ReqBody '[JSON] CaptchaSolution :> Post '[JSON] (JsonTop Bool) -- FIXME: this should return status 200, not 201

thentosCaptchaFrontend :: MonadAction e v m => ServerT ThentosCaptchaFrontend m
thentosCaptchaFrontend =
       preflightH
  :<|> captchaImgH
  :<|> const preflightH
  :<|> captchaWavH

thentosCaptchaBackend :: MonadQuery e v m => ServerT ThentosCaptchaBackend m
thentosCaptchaBackend = captchaSolveH

preflightH :: Applicative m => m (Headers CaptchaOptionsHeaders ())
preflightH = pure $ addCaptchaOptionsHeaders ()

captchaImgH :: MonadAction e v m => m (Headers CaptchaHeaders ImageData)
captchaImgH = uncurry addCaptchaHeaders <$> makeCaptcha

captchaWavH :: MonadAction e v m => ST -> m (Headers CaptchaHeaders SBS)
captchaWavH voice = uncurry addCaptchaHeaders <$> makeAudioCaptcha (cs voice)

captchaSolveH :: MonadQuery e v m => CaptchaSolution -> m (JsonTop Bool)
captchaSolveH (CaptchaSolution cid solution) = JsonTop <$> do
    correct <- solveCaptcha cid solution `catchError` h
    when correct $
        deleteCaptcha cid
    return correct
  where
    h NoSuchCaptchaId = return False
    h e               = throwError e


-- * servant docs

instance HasDocExtras (RestDocs FrontendApi) where
    getCabalPackageName _ = "thentos-core"
    getCabalPackageVersion _ = Paths.version

    getTitle _ = "The thentos API family: Captcha Frontend "

    getIntros _ =
        [ Docs.DocIntro "@@0.2@@Overview" [unlines $
            [ "A lean service that generates visual and audio captchas (called from browsers)."
            ]]]


instance HasDocExtras (RestDocs BackendApi) where
    getCabalPackageName _ = "thentos-core"
    getCabalPackageVersion _ = Paths.version

    getTitle _ = "The thentos API family: Captcha Backend"

    getIntros _ =
        [ Docs.DocIntro "@@0.2@@Overview" [unlines $
            [ "A lean service that verifies whether submitted captcha solutions are correct"
            , "(called as service from backends)."
            ]]]


-- * OPTIONS verb

-- FIXME: this should go elsewhere, ideally to servant, but we only need it here for now.
-- FIXME: not sure if the content type list applies here, as body is always empty.

data Options a

instance {-# OVERLAPPABLE #-} ( GetHeaders (Headers h ()) )
        => HasServer (Options (Headers h ())) context where
    type ServerT (Options (Headers h ())) m = m (Headers h ())
    route Proxy _context = methodRouterHeaders methodOptions (Proxy :: Proxy '[JSON]) ok200

instance {-# OVERLAPPABLE #-} Foreign.HasForeign Foreign.NoTypes ()
        (Options (Headers CaptchaOptionsHeaders ())) where
    type Foreign () (Options (Headers CaptchaOptionsHeaders ())) = Foreign.Req ()
    foreignFor Proxy Proxy Proxy req =
        req & Foreign.reqFuncName . Foreign._FunctionName %~ ("options" :)
            & Foreign.reqMethod .~ "OPTIONS"

instance Docs.HasDocs (Options (Headers CaptchaOptionsHeaders ())) where
    docsFor _ _dat _opts = mempty  -- FIXME: be more helpful here?
