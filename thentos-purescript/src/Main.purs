module Main where

import Control.Monad.Aff
import Control.Monad.Eff
import Control.Monad.Eff.Class
import Control.Monad.Eff.Console (CONSOLE(), log, print)
import Control.Monad.Eff.Exception
import Data.Array (zipWith, range, length)
import Data.Either
import Data.Foreign.Class
import Data.Foreign hiding (parseJSON)
import Data.Generic
import Data.Maybe
import Data.Tuple
import Network.HTTP.Affjax
import Network.HTTP.Affjax.Request
import Network.HTTP.Affjax.Response
import Network.HTTP.Method
import Network.HTTP.MimeType
import Network.HTTP.MimeType.Common
import Network.HTTP.RequestHeader
import Network.HTTP.StatusCode (StatusCode(StatusCode))
import Prelude

import qualified Error as Error
import qualified IFrameStressTest as IFrameStressTest

defRq :: AffjaxRequest Unit
defRq = defaultRequest { headers = [ContentType applicationJSON, Accept applicationJSON] }

type Username = String
type Password = String
type ThentosSessionToken = String


data ThentosError = ConnectionError String | DecodeError String

derive instance genericThentosError :: Generic ThentosError
instance showThentosError :: Show ThentosError where
    show = gShow

data LoginRequestBody = LoginRequestBody
    { user :: Username
    , pass :: Password
    }

instance showLoginRequestBody :: Show LoginRequestBody where
    show (LoginRequestBody { user: n, pass: p }) = "{\"ldName\": " ++ show n ++ ", \"ldPassword\": " ++ show p ++ "}"

loginUser :: forall ajax eff. Username -> Password
    -> Aff (ajax :: AJAX | eff) (Either ThentosError ThentosSessionToken)
loginUser username password = do
    let body :: String
        body = show $ LoginRequestBody { user: username, pass: password }

    res <- affjax defRq
        { method = POST
        , url = "/user/login"
        , content = Just body
        }
    return if res.status == StatusCode 201
            then Right res.response
            else Error.throwJS res.status

{-
        then case eitherDecode res.response of
            Right v -> Right v
            Left e  -> Left $ DecodeError $ "error decoding response: " ++ show (Tuple res.response e)
        else
            Left $ ConnectionError $ "server responsed with error: " ++ show res.status
-}

-- main :: forall ajax err2 console eff. Eff (ajax :: AJAX, err :: EXCEPTION, console :: CONSOLE | eff) Unit
main = do
    log "Hello sailor!"
    runAff throwException print $ loginUser "god" "god"
    IFrameStressTest.main
    LoginIndicator.main