----------------------------------------------------------------------
-- |
-- Module      :  Network.SMTP
-- Copyright   :  (c) Jun Mukai 2006
-- License     :  BSD-style (see the file LICENSE)
-- 
-- Maintainer  :  mukai@jmuk.org
-- Stability   :  unstable
-- Portability :  portable
-- 
-- SMTP client implementation
-- 

module Network.SMTP
    ( Command(..)
    , Response(..)
    , SMTPConnection
    , connectSMTPPort
    , connectSMTP
    , sendCommand
    , closeSMTP
    , sendMail
    , doSMTPPort
    , doSMTP
    )
    where

import Network.TCP
import Network.Stream
import Network.BSD

import Control.Exception
import Control.Monad

import Data.List (intersperse)

import qualified Codec.Binary.Base64 as B64 (encode)

import Prelude hiding (catch)

data SMTPConnection = SMTPC !Connection ![String]

data AuthType = PLAIN_AUTH deriving (Show, Eq)

data Command = HELO String
             | EHLO String
             | MAIL String
             | RCPT String
             | DATA String
             | EXPN String
             | VRFY String
             | HELP String
             | AUTH AuthType String {-^ user name ^-} String {-^ password -}
             | NOOP
             | RSET
             | QUIT
               deriving (Show, Eq)

type ReplyCode = Int

data Response = Ok
              | SystemStatus
              | HelpMessage
              | ServiceReady
              | ServiceClosing
              | UserNotLocal
              | CannotVerify
              | StartMailInput
              | ServiceNotAvailable
              | MailboxUnavailable
              | ErrorInProcessing
              | InsufficientSystemStorage
              | SyntaxError
              | ParameterError
              | CommandNotImplemented
              | BadSequence
              | ParameterNotImplemented
              | MailboxUnavailableError
              | UserNotLocalError
              | ExceededStorage
              | MailboxNotAllowed
              | TransactionFailed
                    deriving (Show, Eq)

codeToResponse :: Num a => a -> Response
codeToResponse 211 = SystemStatus
codeToResponse 214 = HelpMessage
codeToResponse 220 = ServiceReady
codeToResponse 221 = ServiceClosing
codeToResponse 250 = Ok
codeToResponse 251 = UserNotLocal
codeToResponse 252 = CannotVerify
codeToResponse 354 = StartMailInput
codeToResponse 421 = ServiceNotAvailable
codeToResponse 450 = MailboxUnavailable
codeToResponse 451 = ErrorInProcessing
codeToResponse 452 = InsufficientSystemStorage
codeToResponse 500 = SyntaxError
codeToResponse 501 = ParameterError
codeToResponse 502 = CommandNotImplemented
codeToResponse 503 = BadSequence
codeToResponse 504 = ParameterNotImplemented
codeToResponse 550 = MailboxUnavailableError
codeToResponse 551 = UserNotLocalError
codeToResponse 552 = ExceededStorage
codeToResponse 553 = MailboxNotAllowed
codeToResponse 554 = TransactionFailed

crlf = "\r\n"

linesLF ""     = []
linesLF "\r\n" = []
linesLF s      = let (l, s') = break (=='\r') s
                 in case s' of
                      [] -> [l]
                      '\r':'\n':s'' -> l : linesLF s''
                      lf:s''        -> case linesLF s'' of
                                         []    -> [l++"\r"]
                                         hd:tl -> (l++"\r"++hd) : tl
unlinesLF = concat . intersperse crlf

isRight :: Either a b -> Bool
isRight (Right _) = True
isRight _         = False

b64Encode = map (toEnum.fromEnum) . B64.encode . map (toEnum.fromEnum)

-- | connecting SMTP server with the specified name and port number.
connectSMTPPort :: String  -- ^ name of the server
                -> Int     -- ^ port number
                -> IO SMTPConnection
connectSMTPPort hostname port =
    do conn <- openTCPPort hostname port
       (code, msg) <- parseResponse conn
       unless (code == 220) $
              do close conn
                 fail "cannot connect to the server"
       senderHost <- getHostName
       (code, msg) <- sendCommand (SMTPC conn []) (EHLO senderHost) 
       unless (code == 250) $
              do (code, msg) <- sendCommand (SMTPC conn []) (HELO senderHost)
                 unless (code == 250) $
                        do close conn
                           fail "cannot connect to the server"
       return (SMTPC conn (tail $ lines msg))

-- | connecting SMTP server with the specified name and port 25.
connectSMTP :: String     -- ^ name of the server
            -> IO SMTPConnection
connectSMTP = flip connectSMTPPort 25

parseResponse :: Connection -> IO (ReplyCode, String)
parseResponse conn = do lst <- readLines
                        return (read $ fst $ last lst, unlines $ map snd lst)
    where readLines =
              do l <- readLine conn
                 unless (isRight l) $
                        fail "cannot receive the server's response"
                 case span (flip notElem " -") (either (\_ -> "") id l) of
                   (code, '-':msg) -> fmap ((code, msg):) $ readLines
                   (code, ' ':msg) -> return [(code, msg)]


-- | send a method to a server
sendCommand :: SMTPConnection -> Command -> IO (ReplyCode, String)
sendCommand (SMTPC conn _) (DATA dat) =
    do resp <- writeBlock conn $ "DATA\r\n"
       unless (isRight resp) $ fail "cannot send method DATA"
       (code, msg) <- parseResponse conn
       unless (code == 354) $ fail "this server cannot accept any data."
       mapM_ sendLine $ lines dat ++ ["."]
       parseResponse conn
    where sendLine l = do resp <- writeBlock conn (l ++ crlf)
                          unless (isRight resp) $ fail "cannot send data."
sendCommand (SMTPC conn _) (AUTH PLAIN_AUTH username password) =
    do resp <- writeBlock conn command
       unless (isRight resp) $ fail "cannot send data."
       parseResponse conn
    where command = "AUTH PLAIN " ++ b64Encode (concat $ intersperse "\0" [username, username, password])
sendCommand (SMTPC conn _) meth =
    do resp <- writeBlock conn command
       unless (isRight resp) $ fail "cannot send data."
       parseResponse conn
    where command = case meth of
                      (HELO param) -> "HELO " ++ param ++ crlf
                      (EHLO param) -> "EHLO " ++ param ++ crlf
                      (MAIL param) -> "MAIL FROM:<" ++ param ++ ">" ++ crlf
                      (RCPT param) -> "RCPT TO:<" ++ param ++ ">" ++ crlf
                      (EXPN param) -> "EXPN " ++ param ++ crlf
                      (VRFY param) -> "VRFY " ++ param ++ crlf
                      (HELP msg)   -> if null msg
                                        then "HELP\r\n"
                                        else "HELP " ++ msg ++ crlf
                      NOOP         -> "NOOP\r\n"
                      RSET         -> "RSET\r\n"
                      QUIT          -> "QUIT\r\n"

-- | 
-- close the connection.  This function send the QUIT method, so you
-- do not have to QUIT method explicitly.
closeSMTP :: SMTPConnection -> IO ()
closeSMTP c@(SMTPC conn _) = do sendCommand c QUIT
                                close conn


-- | 
-- sending a mail to a server. This is achieved by sendMessage.  If
-- something is wrong, it raises an IOexception.
sendMail :: String   -- ^ sender mail
         -> [String] -- ^ receivers
         -> String   -- ^ data
         -> SMTPConnection
         -> IO ()
sendMail sender receivers dat conn =
    catcher `handle` mainProc
    where mainProc =  do (250, _) <- sendCommand conn (MAIL sender)
                         vals <- mapM (sendCommand conn . RCPT) receivers
                         unless (all ((==250) . fst) vals) $ fail "sendMail error"
                         (250, _) <- sendCommand conn (DATA dat)
                         return ()
          catcher e@(PatternMatchFail _) = fail "sendMail error"
          catcher e = throwIO e

-- | 
-- doSMTPPort open a connection, and do an IO action with the
-- connection, and then close it.
doSMTPPort :: String -> Int -> (SMTPConnection -> IO a) -> IO a
doSMTPPort host port execution =
    bracket (connectSMTPPort host port) closeSMTP execution

-- | 
-- doSMTP is the similar to doSMTPPort, except that it does not
-- require port number but connects to the server with port 25.
doSMTP :: String -> (SMTPConnection -> IO a) -> IO a
doSMTP host execution = doSMTPPort host 25 execution
