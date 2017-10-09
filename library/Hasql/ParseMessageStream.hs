module Hasql.ParseMessageStream where

import Hasql.Prelude hiding (error)
import Hasql.Model hiding (Error(..))
import Control.Monad.Free.Church
import qualified Hasql.ParseMessage as A
import qualified Hasql.ParseDataRow as F
import qualified Hasql.MessageTypePredicates as G
import qualified Hasql.Protocol.Decoding as E
import qualified Hasql.Protocol.Model as C
import qualified BinaryParser as D


{-|
A specification of how to parse a stream of messages.
-}
newtype ParseMessageStream result =
  ParseMessageStream (F (Compose A.ParseMessage (Either Text)) result)
  deriving (Functor, Applicative, Alternative, Monad)

raiseError :: Text -> ParseMessageStream result
raiseError error =
  ParseMessageStream (liftF (Compose (pure (Left error))))

parseMessage :: A.ParseMessage result -> ParseMessageStream result
parseMessage parseMessage =
  ParseMessageStream (liftF (Compose (fmap Right parseMessage)))

error :: ParseMessageStream ErrorMessage
error =
  parseMessage A.error

errorCont :: (ByteString -> ByteString -> result) -> ParseMessageStream result
errorCont message =
  parseMessage (A.errorCont message)

commandComplete :: ParseMessageStream Int
commandComplete =
  parseMessage A.commandComplete

row :: F.ParseDataRow row -> ParseMessageStream row
row pdr =
  parseMessage (A.dataRow pdr) <* parseMessage A.commandCompleteWithoutAmount

rows :: F.ParseDataRow row -> Fold row result -> ParseMessageStream result
rows parseDataRow (Fold foldStep foldStart foldEnd) =
  fold foldStart
  where
    fold !state =
      step <|> end
      where
        step =
          parseMessage (A.dataRow parseDataRow) >>= fold . foldStep state
        end =
          parseMessage (A.commandCompleteWithoutAmount <|> A.emptyQuery) $> foldEnd state

rowsAffected :: ParseMessageStream Int
rowsAffected =
  commandComplete <|> emptyQuery
  where
    commandComplete =
      parseMessage A.commandComplete
    emptyQuery =
      0 <$ parseMessage A.emptyQuery

parseComplete :: ParseMessageStream ()
parseComplete =
  parseMessage A.parseComplete

bindComplete :: ParseMessageStream ()
bindComplete =
  parseMessage A.bindComplete

readyForQuery :: ParseMessageStream ()
readyForQuery =
  parseMessage A.readyForQuery

authentication :: ParseMessageStream AuthenticationResult
authentication =
  do
    traceM ("Getting authentication")
    response <- parseMessage A.authentication
    traceM ("Got a response: " <> show response)
    case response of
      C.OkAuthenticationMessage -> fmap OkAuthenticationResult params
      C.ClearTextPasswordAuthenticationMessage -> return NeedClearTextPasswordAuthenticationResult
      C.MD5PasswordAuthenticationMessage salt -> return (NeedMD5PasswordAuthenticationResult salt)

params :: ParseMessageStream Bool
params =
  iterate (Left "Missing the \"integer_datetimes\" setting")
  where
    iterate !state =
      param <|> readyForQuery
      where
        param =
          do
            (name, value) <- parseMessage A.parameterStatus
            case name of
              "integer_datetimes" -> case value of
                "on" -> iterate (Right True)
                "off" -> iterate (Right False)
                _ -> iterate (Left ("Unexpected value of the \"integer_datetimes\" setting: " <> (fromString . show) value))
              _ -> iterate state
        readyForQuery =
          do
            parseMessage A.readyForQuery
            case state of
              Left error -> raiseError error
              Right result -> return result
