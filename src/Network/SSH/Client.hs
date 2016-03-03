{-# LANGUAGE CPP #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Network.SSH.Client (
    ServerCredential
  , Client(..)
  , ClientState(..)
  , SessionEvent(..)
  , AuthResult(..)
  , defaultClientState
  , defaultGetPassword
  , getPassword
  , sshClient
  ) where

import           Network.SSH.Connection
import           Network.SSH.LoadKeys
import           Network.SSH.Messages
import           Network.SSH.Named
import           Network.SSH.Packet
import           Network.SSH.PubKey
import           Network.SSH.Rekey
import           Network.SSH.Server ( sayHello )
import           Network.SSH.State

import           Control.Concurrent.Async ( withAsync )
import qualified Control.Exception as X
import           Control.Monad ( when )
import qualified Data.ByteString.Char8 as S
import qualified Data.ByteString.Lazy as L
import qualified Data.ByteString.Short as Short
import           Data.IORef ( writeIORef, readIORef )
import           System.IO

#if MIN_VERSION_base(4,8,0)
import           System.Exit ( die )
#else
import           System.Exit ( exitFailure )
die :: String -> IO a
die err = hPutStrLn stderr err >> exitFailure
#endif


-- Public API ------------------------------------------------------------------

data ClientState = ClientState
  { csIdent  :: SshIdent
  , csNet    :: Client
  , csUser   :: S.ByteString
    -- | Optional password provider.
  , csGetPw  :: Maybe (IO S.ByteString)
  , csKeys   :: [Named (SshPubCert, PrivateKey)]
  , csAlgs   :: SshProposalPrefs
    -- | Optional hook to run after transport is setup, but before
    -- auth.
  , csTransportHook :: Maybe (Client -> SshState -> IO ())
    -- | Optional hook to run after the channel loop is running.
  , csChannelHook :: Maybe (Client -> SshState -> IO ())
    -- | Debug level greater than zero means show debug messages.
  , csDebugLevel :: Int
  }

-- | Run an SSh client.
--
-- See 'mkDefaultClientState' for configuration details.
sshClient :: ClientState -> IO ()
sshClient clientSt = do
  -- The '[]' is "server credentials", i.e. server private keys; we
  -- might want client keys here?
  state <- initialState (csDebugLevel clientSt) (csAlgs clientSt) ClientRole []
  debug state "starting client ..."
  let v_c = csIdent clientSt
  let client = csNet clientSt
  debug state "saying hello ..."
  v_s <- sayHello state client v_c
  writeIORef (sshIdents state) (v_s,v_c)

  debug state "starting key exchange ..."
  initialKeyExchange client state
  debug state "key exchange done!"

  maybe (return ()) (\f -> f client state)
    (csTransportHook clientSt)

  debug state "starting auth ..."
  authenticate state clientSt client
  debug state "auth done!"

  debug state "starting channel loop ..."
  -- Kill the connection service when this thread exits.
  withAsync (runConnection client state connectionService) $ \_ -> do
    debug state "channel loop started!"

    debug state "running channel hook ..."
    maybe (return ()) (\f -> f client state)
      (csChannelHook clientSt)
    debug state "channel hook finished!"
    debug state "exiting ..."

-- | Make a client state with reasonable defaults.
--
-- The software version string @version@ will be appended to
-- "SSH-2.0-", telling the remote host to use SSH Protocol Version 2.
--
-- For the host-connection handle @handle@, you can use
--
--   @withSocketsDo $ connectTo host (PortNumber $ fromIntegral port)@
--
-- on non-HaLVM systems after importing @Network@.
--
-- For the password provider @getPw@, use
--
--   @Just $ defaultGetPassword user host@
--
-- if you want to read a password from stdin, use
--
--   @Just $ return "\<pw\>"@
--
-- if you want to hardcode the password @\<pw\>@, and use 'Nothing' if
-- you don't want to use passwords.
--
-- If the optional key file in @keyFile@ is not provided, then the
-- client will have no keys, and can only do password auth.
--
-- If the optional algorithm prefs in @prefs@ are not provided, then
-- all supported algorithms will be used.
--
-- If the optional transport hook in @hook@ is not provided, then no
-- transport hook is run.
defaultClientState ::
  Int                                 {- ^ debug level                -} ->
  String                              {- ^ software version           -} ->
  String                              {- ^ user                       -} ->
  String                              {- ^ host name                  -} ->
  Int                                 {- ^ port                       -} ->
  Handle                              {- ^ host connection            -} ->
  Maybe (IO S.ByteString)             {- ^ optional password provider -} ->
  Maybe FilePath                      {- ^ optional private key file  -} ->
  Maybe SshProposalPrefs              {- ^ optional algorithm prefs   -} ->
  Maybe (Client -> SshState -> IO ()) {- ^ optional transport hook    -} ->
  Maybe (Client -> SshState -> IO ()) {- ^ optional channel hook      -} ->
  IO ClientState
defaultClientState csDebugLevel version user _host _port handle getPw
  keyFile prefs transportHook channelHook = do
  let csIdent = sshIdent $ S.pack version
  let csNet   = mkDefaultClient handle
  let csUser  = S.pack user
  let csGetPw = getPw
  csKeys     <- maybe (return []) loadPrivateKeys keyFile
  let csAlgs  = maybe allAlgsSshProposalPrefs id prefs
  let csTransportHook = transportHook
  let csChannelHook   = channelHook
  return ClientState{..}

mkDefaultClient :: Handle -> Client
mkDefaultClient h =
  defaultClient
    { cGet   = S.hGetSome h
    , cPut   = S.hPutStr  h . L.toStrict
    , cClose =   hClose   h
    , cLog   = putStrLn
    }

-- | A default 'csGetPw' implementation.
--
-- Uses the OpenSSH password prompt.
defaultGetPassword :: String -> String -> IO S.ByteString
defaultGetPassword user host =
  getPassword $ user ++ "@" ++ host ++ "'s password: "

-- | Read a line from @stdin@ with echo disabled.
getPassword :: String -> IO S.ByteString
-- Based on http://stackoverflow.com/a/4064482/470844
getPassword prompt = do
  putStr prompt
  hFlush stdout
  pass <- withEcho False S.getLine
  putChar '\n'
  return pass
  where
  withEcho :: Bool -> IO a -> IO a
  withEcho echo action = do
    old <- hGetEcho stdin
    X.bracket_ (hSetEcho stdin echo) (hSetEcho stdin old) action

authenticate :: SshState -> ClientState -> Client -> IO ()
authenticate state clientSt client = do
  debug state "requesting ssh-userauth service from server ..."
  send client state (SshMsgServiceRequest SshUserAuth)
  SshMsgServiceAccept service <-
    receiveSpecific SshMsgTagServiceAccept client state
  when (service /= SshUserAuth) $
    send client state $
      SshMsgDisconnect SshDiscProtocolError
        "unexpected service, expected 'ssh-userauth'!" ""
  debug state "server accepted ssh-userauth service request!"
  
  -- let svc  = SshServiceOther "no-such-service@galois.com"
  debug state $ "attempting to log in as \"" ++ S.unpack user ++ "\" ..."

  success <- publicKeyAuthLoop (csKeys clientSt)

  when (not success) $ do
    success' <- case csGetPw clientSt of
      Nothing    -> return False
      Just getPw -> passwordAuth getPw
    when (not success') $
      die "could not log in!"

  where
  svc  = SshConnection
  user = csUser clientSt

  passwordAuth getPw = do
    debug state "attempting password ..."
    pw <- getPw
    send client state
      (SshMsgUserAuthRequest user svc
        (SshAuthPassword pw Nothing))
    handleAuthResponse "password"

  publicKeyAuthLoop []           = return False
  publicKeyAuthLoop (cred:creds) = do
    debug state "attempting public key ..."
    let pubKeyAlg            = Short.fromShort $ nameOf cred
    let (pubKey, privateKey) = namedThing cred
    Just sid                <- readIORef (sshSessionId state)
    let token = pubKeyAuthenticationToken sid user svc pubKeyAlg pubKey
    sig      <- sign privateKey token
    send client state
      (SshMsgUserAuthRequest user svc
        (SshAuthPublicKey pubKeyAlg pubKey (Just sig)))
    success <- handleAuthResponse "publickey"
    if success
    then return True
    else publicKeyAuthLoop creds

  handleAuthResponse :: String -> IO Bool
  handleAuthResponse type' = do
    response <- receive client state
    case response of
      SshMsgUserAuthSuccess -> do
        debug state $ "successfully logged in using " ++ type' ++ "!"
        return True
      SshMsgUserAuthFailure methods partialSuccess
        | null methods
        , not partialSuccess -> die "could not log in!"
        | otherwise          -> do
            debug state $ type' ++ " login failed! can continue with: " ++
                          show methods
            return False
      _ -> fail "handleAuthResponse: unexpected response!"
