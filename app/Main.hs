{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Main where

import           Control.Monad.Trans
import           Data.Maybe
import qualified Data.Text                   as T
import           Data.Time
import           Data.Time.Calendar.WeekDate
import           GHC.Generics
import           Network.HTTP.Client         (newManager)
import           Network.HTTP.Client.TLS     (tlsManagerSettings)
import           Servant.Common.Req          (ServantError)
import           System.Envy
import           Web.Spock
import           Web.Spock.Config
import qualified Web.Telegram.API.Bot        as TGM

data BKConfig = BKConfig {
    port           :: Int -- "PORT"
  , tgmbkToken     :: T.Text -- "TGMBK_TOKEN"
  , tgmbkLocations :: [T.Text] -- "TGMBK_LOCATIONS"
  , tgmbkLocation404Msg :: T.Text -- "TGMBK_LOCATION_404_MSG"
  } deriving (Generic, Show)

instance DefConfig BKConfig where
  defConfig = BKConfig 8080 "" ["Mon", "Tue", "Wed", "Thu", "Fri"] "No breakfast for you (≧∇≦)b"

instance FromEnv BKConfig

instance System.Envy.Var [T.Text] where
  toVar =  T.unpack . T.intercalate ", "
  fromVar = Just . (map T.strip) . (T.splitOn ",") . T.pack

data MySession = EmptySession
data MyAppState = MyAppState BKConfig

main :: IO ()
main =
    do (Right cfg) <- decodeEnv :: IO (Either String BKConfig)
       runApp cfg

runApp :: BKConfig -> IO ()
runApp cfg =
    do let path = T.unpack . tgmbkToken $ cfg
       let port' = port cfg
       spockCfg <- defaultSpockCfg EmptySession PCNoDatabase (MyAppState cfg)
       runSpock port' (spock spockCfg (app path))

app :: String -> SpockM () MySession MyAppState ()
app pathToListen =
    do get root $
           text ""
       post (static pathToListen) $
            do (MyAppState (BKConfig {
                    tgmbkToken=token
                  , tgmbkLocations=locations
                  , tgmbkLocation404Msg=location404Msg
                  })) <- getState
               TGM.Update { TGM.message=Just m } <- jsonBody'
               let hasTomorrow = case TGM.text m of
                                  Just x  -> T.isInfixOf (T.toCaseFold "tomorrow") (T.toCaseFold x)
                                  Nothing -> False
               dayOfWeek <- liftIO $ localDayOfWeek <$> getCurrentTime

               let messageText = locationMessage hasTomorrow dayOfWeek locations location404Msg
               let chatID = TGM.chat_id . TGM.chat $ m
               let messageID = TGM.message_id m

               let req = replyToMessageRequest chatID messageText messageID
               resp <- liftIO $ doSendMessage (TGM.Token token) req
               case resp of
                   Left _ -> do
                     liftIO $ putStrLn "Request failed"
                   Right (TGM.Response _) -> do
                     liftIO $ putStrLn "Request succeded"

               text ""

-- it's certainly a very bad function
locationMessage :: Bool -> Int -> [T.Text] -> T.Text -> T.Text
locationMessage True dow = locationMessage' (nextDay dow)
locationMessage _    dow = locationMessage' dow

locationMessage' :: Int -> [T.Text] -> T.Text -> T.Text
locationMessage' dow locations defaultMsg =
    fromMaybe defaultMsg (locations `safeIndex` (dow - 1))

nextDay :: Int -> Int
nextDay day = ((day `mod` 7) + 1)

safeIndex :: [a] -> Int -> Maybe a
safeIndex xs i
    | i < length xs = Just $ xs !! i
    | otherwise     = Nothing

hkt :: TimeZone
hkt = TimeZone 480 False "HKT"

localDayOfWeek :: UTCTime -> Int
localDayOfWeek = (\(_, _, dayOfWeek) -> dayOfWeek)
               . toWeekDate
               . localDay
               . utcToLocalTime hkt

replyToMessageRequest :: Int -> T.Text -> Int -> TGM.SendMessageRequest
replyToMessageRequest chatID bodyText replyToMsgID = TGM.SendMessageRequest (showT chatID) bodyText Nothing Nothing Nothing (Just replyToMsgID) Nothing

doSendMessage :: TGM.Token
                 -> TGM.SendMessageRequest
                 -> IO (Either ServantError TGM.MessageResponse)
doSendMessage token req = do
    manager <- newManager tlsManagerSettings
    TGM.sendMessage token req manager

showT :: Show a => a -> T.Text
showT = T.pack . show
