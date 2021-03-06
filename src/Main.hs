{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}

import           Control.Applicative        (Applicative, (<$>), (<*>))
import           Control.Exception          (SomeException (..), try)
import           Control.Lens
import           Control.Monad
import           Control.Monad.Error.Class  (MonadError, catchError, throwError)
import           Control.Monad.IO.Class     (MonadIO, liftIO)
import           Control.Monad.Reader       (MonadReader, ReaderT, asks,
                                             runReaderT)
import           Control.Monad.Trans
import           Control.Monad.Trans.Either (EitherT (..), runEitherT)
import           Data.Aeson
import           Data.ByteString.Lazy.Char8 (ByteString)
import           Data.Char                  (toLower, toUpper)
import           Data.List                  (intercalate)
import           Data.Maybe                 (listToMaybe)
import           Data.Text                  (pack)
import           Network.Wreq
import           System.Environment         (getArgs, getEnv)

type Word = String

newtype SynonymList = SynonymList {synonyms :: [Word]} deriving (Eq, Show)

newtype AntonymList = AntonymList {antonyms :: [Word]} deriving (Eq, Show)

instance FromJSON SynonymList where
  parseJSON (Object v) = SynonymList <$> (v .: "synonyms")

instance FromJSON AntonymList where
  parseJSON (Object v) = AntonymList <$> (v .: "antonyms")

data WordsConfig = WordsConfig
                    { accessToken :: String }

newtype WordsApp a = WordsApp
                    { runW :: EitherT WordsError (ReaderT WordsConfig IO) a }
                    deriving (Functor, Applicative, Monad,
                              MonadReader WordsConfig, MonadIO,
                              MonadError WordsError)

data WordsError = NoResults
                | InvalidConfig
                | InvalidArgs
                deriving (Eq, Show, Read)

class Display d where
  display :: d -> String

instance Display WordsError where
  display | NoResults = "no results found"
          | InvalidConfig = "invalid configuration"
          | InvalidArgs = "invalid arguments"

data RequestType = Synonyms
                 | Antonyms
                 deriving (Eq, Show, Read)

data WordsRequest = WordsRequest { requestType :: RequestType
                                 , word        :: Word } deriving (Eq, Show)

type WordsEnv = EitherT WordsError IO

app :: WordsEnv String
app = do
  cfg <- getConfig
  req <- parseRequest
  EitherT $ runWordsApp (handleRequest req) cfg

main :: IO ()
main = (runEitherT safe) >>= displayResults where
  safe = app `catchError` errorHandler

runWordsApp :: WordsApp a -> WordsConfig -> IO (Either WordsError a)
runWordsApp w cfg = runReaderT (runEitherT (runW w)) cfg

getConfig :: WordsEnv WordsConfig
getConfig = do
  e <- liftIO $ try (getEnv "WORDS_TOKEN")
  case e of
    Left (SomeException _) -> throwError InvalidConfig
    Right token -> return (WordsConfig token)

guard' :: Bool -> WordsError -> WordsEnv ()
guard' b e = if b then return () else throwError e

capitalize :: String -> String
capitalize [] = []
capitalize (h:t) = toUpper h : map toLower t

parseReqString :: String -> WordsEnv RequestType
parseReqString s = do
  let maybeRes = (listToMaybe . reads) (capitalize s) :: Maybe (RequestType, String)
  (reqType, excess) <- maybe (throwError InvalidArgs) return maybeRes
  guard' (null excess) InvalidArgs
  return reqType

parseRequest :: WordsEnv WordsRequest
parseRequest = do
  args <- liftIO getArgs
  guard' (length args == 2) InvalidArgs
  let [reqString, word] = args
  reqType <- parseReqString reqString
  return $ WordsRequest reqType word

displayResults :: Either WordsError String -> IO ()
displayResults (Left e) = putStrLn $ display e
displayResults (Right r) = putStrLn r

errorHandler :: WordsError -> WordsEnv String
errorHandler = return . display

handleRequest :: WordsRequest -> WordsApp String
handleRequest WordsRequest{..} = case requestType of
  Synonyms -> liftM (intercalate ", ") (getSynonyms word)
  Antonyms -> liftM (intercalate ", ") (getAntonyms word)
  _ -> throwError InvalidArgs

listToMaybe' :: [a] -> Maybe [a]
listToMaybe' [] = Nothing
listToMaybe' xs = Just xs

getSynonyms :: Word -> WordsApp [Word]
getSynonyms w = do
            json <- getJSONEndpoint w "synonyms"
            let res = decode json >>= listToMaybe' . synonyms
            maybe (throwError NoResults) return res

getAntonyms :: Word -> WordsApp [Word]
getAntonyms w = do
            json <- getJSONEndpoint w "antonyms"
            let res = decode json >>= listToMaybe' . antonyms
            maybe (throwError NoResults) return res

-- URL utility functions

type URL = String

baseURL :: URL
baseURL = "http://www.wordsapi.com/words"

buildURL :: Word -> String -> URL
buildURL w endpoint = intercalate "/" [baseURL, w, endpoint]

tryGetWith :: Options -> URL -> WordsApp (Response ByteString)
tryGetWith opts url = do
  req <- (liftIO . try) $ getWith opts url
  case req of
    Left (SomeException _) -> throwError NoResults
    Right res -> return res

getJSON :: URL -> WordsApp ByteString
getJSON url = do
  token <- asks accessToken
  let opts = defaults & param "accessToken" .~ [pack token]
  liftM (^. responseBody) $ tryGetWith opts url

getJSONEndpoint :: Word -> String -> WordsApp ByteString
getJSONEndpoint w e = getJSON (buildURL w e)
