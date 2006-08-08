{-# OPTIONS_GHC -cpp -fglasgow-exts #-}
-- examples to connect server by hsgnutls

import Network.GnuTLS
import Network
import HaskellNet.BSStream

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Base as BSB

import Data.IORef
import Control.Monad

import Foreign.ForeignPtr
import Foreign.Ptr

data TlsSession t = TlsSession { sess :: Session t
                               , buf  :: IORef ByteString }

fromSession :: Session t -> IO (TlsSession t)
fromSession s = do newbuf <- newIORef BS.empty
                   return $ TlsSession s newbuf

extendBuf sess@(TlsSession s buf) =
    do res <- mallocForeignPtrBytes 1024
       len <- withForeignPtr res (\p -> tlsRecv s p 1024)
       modifyIORef buf (flip BS.append $ BSB.fromForeignPtr res len)
       unless (len <= 1024) $ extendBuf sess

instance BSStream (TlsSession t) where
#if defined(__GLASGOW_HASKELL__)
    bsGetLine sess@(TlsSession s buf) =
        do bufstr <- readIORef buf
           when (BS.null bufstr) $ extendBuf sess
           bufstr' <- readIORef buf
           let (line, rest) =  BS.span (/='\n') bufstr'
           writeIORef buf $ BS.tail rest
           return line
    bsGetLines sess = fmap BS.lines $ bsGetContents sess
    bsGetNonBlocking = bsGet
#endif
    bsGetContents sess@(TlsSession s buf) =
        do extendBuf sess
           bufstr <- readIORef buf
           writeIORef buf BS.empty
           return bufstr
    bsGet sess@(TlsSession s buf) len =
        do bufstr <- readIORef buf
           when (BS.length bufstr > len) $ extendBuf sess
           bufstr' <- readIORef buf
           let (r, bufstr'') = BS.splitAt len bufstr'
           writeIORef buf bufstr''
           return r
    bsPut (TlsSession s _) bs =
        do withForeignPtr fptr $ \ptr -> (tlsSend s (plusPtr ptr off) len)
           return ()
        where (fptr, off, len) = BSB.toForeignPtr bs
    bsPutStrLn sess bs = bsPut sess (BS.append bs $ BS.singleton '\n')
    bsClose (TlsSession s _) = bye s ShutRdwr


connectTLS host port =
    do s <- tlsClient [handle :=> connectTo host port, priorities := [CrtX509, CrtOpenpgp]]
       cred <- certificateCredentials
       set s [ credentials := cred]
       handshake s
       fromSession s

