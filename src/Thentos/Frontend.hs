{-# LANGUAGE DataKinds              #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE OverloadedStrings      #-}
{-# LANGUAGE ScopedTypeVariables    #-}

module Thentos.Frontend where

import Control.Applicative (pure, (<$>), (<*>))
import Control.Concurrent.MVar (MVar)
import Crypto.Random (SystemRNG)
import Data.ByteString (ByteString)
import Data.Configifier ((>>.))
import Data.Monoid ((<>))
import Data.Proxy (Proxy(Proxy))
import Data.String.Conversions (cs)
import Snap.Blaze (blaze)
import Snap.Core (ifTop, Method(GET, POST), method, redirect')
import Snap.Http.Server (defaultConfig, setBind, setPort)
import Snap.Snaplet.AcidState (acidInitManual)
import Snap.Snaplet.Session.Backends.CookieSession (initCookieSessionManager)
import Snap.Snaplet (SnapletInit, makeSnaplet, nestSnaplet, addRoutes)
import System.Log.Missing (logger)
import System.Log (Priority(INFO))

import Thentos.Api
import Thentos.Config
import Thentos.Frontend.Types
import Thentos.Frontend.Util (serveSnaplet)
import Thentos.Types (Role(..))

import qualified Text.Blaze.Html5 as Blaze
import qualified Thentos.Frontend.Handlers as H
import qualified Thentos.Frontend.Pages as P


runFrontend :: HttpConfig -> ActionStateGlobal (MVar SystemRNG) -> IO ()
runFrontend config asg = do
    logger INFO $ "running frontend on " <> show (bindUrl config) <> "."
    serveSnaplet (setBind host $ setPort port defaultConfig) (frontendApp asg config)
  where
    host :: ByteString = cs $ config >>. (Proxy :: Proxy '["bind_host"])
    port :: Int = config >>. (Proxy :: Proxy '["bind_port"])

frontendApp :: ActionStateGlobal (MVar SystemRNG) -> HttpConfig -> SnapletInit FrontendApp FrontendApp
frontendApp (st, rn, _cfg) feConf =
    makeSnaplet "Thentos" "The Thentos universal user management system" Nothing $ do
        addRoutes routes
        FrontendApp <$>
            (nestSnaplet "acid" db $ acidInitManual st) <*>
            (return rn) <*>
            (return _cfg) <*>
            (nestSnaplet "sess" sess $
               initCookieSessionManager "site_key.txt" "sess" (Just 3600)) <*>
            (pure feConf)

routes :: [(ByteString, FH ())]
routes = [ ("", ifTop $ H.index)

         , ("login_thentos", H.loginThentos)
         , ("logout_thentos", method GET H.logoutThentos)
         , ("logout_thentos", method POST H.loggedOutThentos)
         , ("user/create", H.userCreate)
         , ("user/create_confirm", H.userCreateConfirm)
         , ("user/reset_password_request", H.resetPasswordRequest)
         , ("user/reset_password", H.resetPassword)
         , ("user/update", H.userUpdate)
         , ("user/update_email", H.emailUpdate)
         , ("user/update_email_confirm", H.emailUpdateConfirm)
         , ("user/update_password", H.passwordUpdate)
         , ("service/create", H.runWithUserClearance H.serviceCreate)
         , ("login_service", H.loginService)
         , ("check_thentos_login", H.checkThentosLogin)  -- FIXME: what is this used for?  drop it?

         -- (dashboard should probably be a snaplet.  if only for the
         -- routing table and the call to the dashboardPagelet.)

         , ("/dashboard", redirect' "/dashboard/details" 303)
         , ("/dashboard/details", H.dashboardDetails)

         , ("test", blaze $ P.dashboardPagelet
                 [RoleUser, RoleUserAdmin, RoleServiceAdmin, RoleAdmin]
                 P.DashboardTabDetails
                 (Blaze.text "body"))
         ]
