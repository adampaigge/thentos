{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns      #-}

module Thentos.Frontend.Pages
    ( indexPage
    , userCreatePage
    , userCreateRequestedPage
    , userCreatedPage
    , serviceCreatePage
    , serviceCreateForm
    , serviceCreatedPage
    , userCreateForm
    , loginServicePage
    , loginThentosPage
    , loginThentosForm
    , resetPasswordRequestPage
    , resetPasswordRequestForm
    , resetPasswordPage
    , resetPasswordForm
    , resetPasswordRequestedPage
    , errorPage
    , notLoggedInPage
    ) where

import Control.Applicative ((<$>), (<*>))
import Data.ByteString (ByteString)
import Data.Maybe (isJust)
import Data.Monoid ((<>))
import Data.String.Conversions (cs)
import Data.Text (Text)
import Text.Blaze.Html (Html, (!))
import Text.Digestive.Blaze.Html5 (form, inputText, inputPassword, label, inputSubmit)
import Text.Digestive.Form (Form, check, validate, text, (.:))
import Text.Digestive.Types (Result(Success, Error))
import Text.Digestive.View (View)

import qualified Data.Text as T
import qualified Text.Blaze.Html5 as H
import qualified Text.Blaze.Html5.Attributes as A

import Thentos.Types

indexPage :: Html
indexPage = do
    H.head $ do
        H.title "Thentos main page"
    H.body $ do
        H.h3 $ do
            "things you can do from here:"
        H.ul $ do
            H.li . (H.a ! A.href "/login_thentos") $ "login"
            H.li . (H.a ! A.href "/user/create") $ "create user"
            H.li . (H.a ! A.href "/service/create") $ "create service"
            H.li . (H.a ! A.href "/user/reset_password_request") $ "request password reset"

userCreatePage :: View Html -> Html
userCreatePage v = H.docTypeHtml $ do
    H.head $ do
        H.title "Create user"
    H.body $ do
        -- FIXME: how do we avoid having to duplicate the URL here?
        form v "create" $ do
            H.p $ do
                label "name" v "User name:"
                inputText "name" v
            H.p $ do
                label "password1" v "Password:"
                inputPassword "password1" v
            H.p $ do
                label "password2" v "Repeat Password:"
                inputPassword "password2" v
            H.p $ do
                label "email" v "Email Address:"
                inputText "email" v
            inputSubmit "Create User" ! A.id "create_user_submit"

userCreateRequestedPage :: Html
userCreateRequestedPage = H.string $ "Please check your email"

userCreatedPage :: UserId -> Html
userCreatedPage uid =
    H.docTypeHtml $ do
        H.head $
            H.title "Success!"
        H.body $ do
            H.h1 "Added a user!"
            H.pre . H.string $ show uid

serviceCreatePage :: View Html -> Html
serviceCreatePage v = H.docTypeHtml $ do
    H.head $ do
        H.title "Create Service"
    H.body $ do
        form v "create" $ do
            H.p $ do
                label "name" v "Service name:"
                inputText "name" v
            H.p $ do
                label "description" v "Service description:"
                inputText "description" v
            inputSubmit "Create Service" ! A.id "create_service_submit"

serviceCreateForm :: Monad m => Form Html m (ServiceName, ServiceDescription)
serviceCreateForm =
    (,) <$>
        (ServiceName <$> "name" .: check "name must not be empty" nonEmpty (text Nothing)) <*>
        (ServiceDescription <$> "description" .: check "description must not be mpty" nonEmpty (text Nothing))

serviceCreatedPage :: ServiceId -> ServiceKey -> Html
serviceCreatedPage sid key = H.docTypeHtml $ do
    H.head $ do
        H.title "Service created!"
    H.body $ do
        H.body $ do
            H.h1 "Added a service!"
            H.p "Service id: " <> H.text (fromServiceId sid)
            H.p "Service key: " <> H.text (fromServiceKey key)

userCreateForm :: Monad m => Form Html m UserFormData
userCreateForm = (validate validateUserData) $ (,,,)
    <$> (UserName  <$> "name"      .: check "name must not be empty"        nonEmpty   (text Nothing))
    <*> (UserPass <$> "password1"  .: check "password must not be empty"    nonEmpty   (text Nothing))
    <*> (UserPass <$> "password2"  .: check "password must not be empty"    nonEmpty   (text Nothing))
    <*> (UserEmail <$> "email"     .: check "must be a valid email address" checkEmail (text Nothing))
  where
    checkEmail :: Text -> Bool
    checkEmail = isJust . T.find (== '@')

    validateUserData (name, pw1, pw2, email)
        | pw1 == pw2 = Success $ UserFormData name pw1 email
        | otherwise  = Error "Passwords don't match"

loginServicePage :: ServiceId -> View Html -> ByteString -> Html
loginServicePage (H.string . cs . fromServiceId -> serviceId) v reqURI =
    H.docTypeHtml $ do
        H.head $
            H.title "Log in"
        H.body $ do
            H.p $ do
                "service id: " <> serviceId
            form v (cs reqURI) $ do
                H.p $ do
                    label "usernamme" v "User name:"
                    inputText "name" v
                H.p $ do
                    label "password" v "Password:"
                    inputPassword "password" v
                inputSubmit "Log in"

loginThentosPage :: View Html -> Html
loginThentosPage v = do
    H.docTypeHtml $ do
        H.head $
            H.title "Log into thentos"
        H.body $ do
            form v "login_thentos" $ do
                H.p $ do
                    label "usernamme" v "User name:"
                    inputText "name" v
                H.p $ do
                    label "password" v "Password:"
                    inputPassword "password" v
                inputSubmit "Log in" ! A.id "login_submit"

loginThentosForm :: Monad m => Form Html m (UserName, UserPass)
loginThentosForm = (,)
    <$> (UserName  <$> "name"    .: check "name must not be empty"     nonEmpty   (text Nothing))
    <*> (UserPass <$> "password" .: check "password must not be empty" nonEmpty   (text Nothing))

resetPasswordRequestPage :: View Html -> Html
resetPasswordRequestPage v =
    H.docTypeHtml $ do
        H.head $ H.title "Reset your password"
        H.body $ do
            form v "reset_password_request" $ do
                H.p $ do
                    label "email" v "Email address: "
                    inputText "email" v
                inputSubmit "Reset your password"

resetPasswordRequestForm :: Monad m => Form Html m UserEmail
resetPasswordRequestForm =
    UserEmail <$> "email" .: check "email address must not be empty" nonEmpty (text Nothing)

resetPasswordPage :: Text -> View Html -> Html
resetPasswordPage reqUrl v =
    H.docTypeHtml $ do
        H.head $ H.title "Enter a new password"
        H.body $ do
            form v reqUrl $ do
                H.p $ do
                    label "password1" v "New password: "
                    inputPassword "password1" v
                H.p $ do
                    label "password2" v "repeat password: "
                    inputPassword "password2" v
                inputSubmit "Set your new password"

resetPasswordForm :: Monad m => Form Html m UserPass
resetPasswordForm = (validate validatePass) $
    (,)
      <$> (UserPass <$> "password1" .: check "password must not be empty" nonEmpty (text Nothing))
      <*> (UserPass <$> "password2" .: check "password must not be empty" nonEmpty (text Nothing))
  where
    validatePass :: (UserPass, UserPass) -> Result Html UserPass
    validatePass (p1, p2) = if p1 == p2
                                then Success p1
                                else Error "passwords don't match"

resetPasswordRequestedPage :: Html
resetPasswordRequestedPage = H.string $ "Please check your email"

errorPage :: String -> Html
errorPage errorString = H.string $ "Encountered error: " ++ show errorString

notLoggedInPage :: Html
notLoggedInPage = H.docTypeHtml $ do
    H.head $ H.title "Not logged in"
    H.body $ do
        H.p "You're currently not logged into Thentos."
        H.p $ "Please go to " <> loginLink <> " and try again."
  where
    loginLink = H.a ! A.href "/login_thentos" $ "login"


-- * auxillary functions

nonEmpty :: Text -> Bool
nonEmpty = not . T.null
