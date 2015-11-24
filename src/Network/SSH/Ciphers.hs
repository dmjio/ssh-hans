{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RecordWildCards #-}

module Network.SSH.Ciphers (
    Cipher(..)

  , cipher_none
  , cipher_aes128_cbc
  , cipher_aes128_ctr
  , cipher_aes128_gcm
  ) where

import qualified Data.ByteString as S
import qualified Data.ByteString.Char8 as S8
import qualified Data.ByteString.Lazy as L

import           Crypto.Error
import           Crypto.Cipher.AES
import qualified Crypto.Cipher.Types as Cipher

import           Control.Applicative
import           Data.Serialize
import           Data.Word
import           Data.ByteArray (convert)
import           Data.Monoid ((<>))

import           Network.SSH.Keys

-- | A streaming cipher.
data Cipher = forall st. Cipher
  { cipherName  :: !S.ByteString
  , blockSize   :: !Int
  , paddingSize :: Int -> Int
  , cipherState :: st
  , getLength   :: st -> S.ByteString -> Int
  , encrypt     :: st -> S.ByteString -> (st, S.ByteString)
  , decrypt     :: st -> S.ByteString -> (st, S.ByteString)
  }

instance Show Cipher where
  show Cipher { .. } = S8.unpack cipherName

-- Supported Ciphers -----------------------------------------------------------

grab :: Int -> L.ByteString -> S.ByteString
grab n = L.toStrict . L.take (fromIntegral n)

cipher_none :: Cipher
cipher_none  =
  Cipher { cipherName      = "none"
         , blockSize = 8
         , cipherState = ()
         , encrypt = \_ x -> ((), x)
         , decrypt = \_ x -> ((), x)
         , getLength = \_ -> either undefined fromIntegral . runGet getWord32be
         , paddingSize = roundUp 8
         }

cipher_aes128_cbc :: CipherKeys -> Cipher
cipher_aes128_cbc CipherKeys { ckInitialIV = initial_iv, ckEncKey = key } = cipher
  where

  aesKey :: AES128
  CryptoPassed aesKey = Cipher.cipherInit (grab keySize key)
  Cipher.KeySizeFixed keySize = Cipher.cipherKeySize aesKey

  iv0    :: Cipher.IV AES128
  Just iv0 = Cipher.makeIV (grab ivSize initial_iv)
  ivSize  = Cipher.blockSize aesKey

  cipher =
    Cipher { cipherName  = "aes128-cbc"
           , blockSize   = ivSize
           , encrypt     = enc
           , decrypt     = dec
           , cipherState = iv0
           , paddingSize = roundUp 16
           , getLength   = \st block ->
                           either undefined fromIntegral
                         $ runGet getWord32be
                         $ snd -- ignore new state
                         $ dec st block
           }

  enc :: Cipher.IV AES128 -> S.ByteString -> (Cipher.IV AES128, S.ByteString)
  enc iv bytes = (iv', cipherText)
    where
    cipherText = Cipher.cbcEncrypt aesKey iv bytes
    Just iv' = Cipher.makeIV (S.drop (S.length bytes - ivSize) cipherText)

  dec :: Cipher.IV AES128 -> S.ByteString -> (Cipher.IV AES128, S.ByteString)
  dec iv cipherText = (iv', bytes)
    where
    bytes = Cipher.cbcDecrypt aesKey iv cipherText
    Just iv' = Cipher.makeIV
             $ S.drop (S.length cipherText - ivSize)
             $ cipherText

cipher_aes128_ctr :: CipherKeys -> Cipher
cipher_aes128_ctr CipherKeys { ckInitialIV = initial_iv, ckEncKey = key } = cipher
  where

  aesKey :: AES128
  CryptoPassed aesKey = Cipher.cipherInit (grab keySize key)
  Cipher.KeySizeFixed keySize = Cipher.cipherKeySize aesKey

  iv0    :: Cipher.IV AES128
  Just iv0 = Cipher.makeIV (grab ivSize initial_iv)
  ivSize  = Cipher.blockSize aesKey

  cipher =
    Cipher { cipherName  = "aes128-ctr"
           , blockSize   = ivSize
           , encrypt     = enc
           , decrypt     = enc
           , cipherState = iv0
           , paddingSize = roundUp 16
           , getLength   = \st block ->
                           either undefined fromIntegral
                         $ runGet getWord32be
                         $ snd -- ignore new state
                         $ enc st block
           }

  enc iv bytes = (iv', cipherText)
    where
    cipherText = Cipher.ctrCombine aesKey iv bytes
    iv' = Cipher.ivAdd iv
        $ S.length bytes `quot` ivSize

cipher_aes128_gcm :: CipherKeys -> Cipher
cipher_aes128_gcm CipherKeys { ckInitialIV = initial_iv, ckEncKey = key } = cipher
  where
  lenLen, ivLen, tagLen :: Int
  lenLen = 4
  ivLen = 12
  tagLen = 16

  aesKey :: AES128
  CryptoPassed aesKey         = Cipher.cipherInit $ grab keySize key
  Cipher.KeySizeFixed keySize = Cipher.cipherKeySize aesKey
  aesBlockSize                = Cipher.blockSize aesKey

  cipher =
    Cipher { cipherName  = "aes128-gcm@openssh.com"
           , blockSize   = aesBlockSize
           , encrypt     = enc
           , decrypt     = dec
           , cipherState = invocation_counter0
           , paddingSize = roundUp aesBlockSize . subtract lenLen
           , getLength   = \_ block ->
                           (+) tagLen -- get the tag, too
                         $ either undefined fromIntegral
                         $ runGet getWord32be block
           }

  Right (fixed, invocation_counter0) =
    runGet (liftA2 (,) getWord32be getWord64be)
           (grab ivLen initial_iv)

  mkAead :: Word64 -> Cipher.AEAD AES128
  mkAead counter
    = throwCryptoError
    $ Cipher.aeadInit Cipher.AEAD_GCM aesKey
    $ runPut
    $ putWord32be fixed >> putWord64be counter

  dec :: Word64 -> S.ByteString -> (Word64, S.ByteString) -- XXX: failable
  dec invocation_counter input_text = (invocation_counter+1, len_part<>plain_text)
    where
    (len_part,(cipher_text,auth_tag))
         = fmap (S.splitAt (S.length input_text-(tagLen+lenLen)))
                (S.splitAt lenLen input_text)

    Just plain_text =
      Cipher.aeadSimpleDecrypt
        (mkAead invocation_counter) len_part cipher_text
        (Cipher.AuthTag (convert auth_tag))

  enc :: Word64 -> S.ByteString -> (Word64, S.ByteString)
  enc invocation_counter input_text =
    (invocation_counter+1, S.concat [len_part,cipher_text,convert auth_tag])
    where
    (len_part,plain_text) = S.splitAt lenLen input_text

    (Cipher.AuthTag auth_tag, cipher_text) =
      Cipher.aeadSimpleEncrypt (mkAead invocation_counter) len_part plain_text tagLen


roundUp ::
  Int {- ^ target multiple -} ->
  Int {- ^ body length     -} ->
  Int {- ^ padding length  -}
roundUp align bytesLen = paddingLen
  where
  bytesRem   = (4 + 1 + bytesLen) `mod` align

  -- number of bytes needed to align on block size
  alignBytes | bytesRem == 0 = 0
             | otherwise     = align - bytesRem

  paddingLen | alignBytes == 0 =              align
             | alignBytes <  4 = alignBytes + align
             | otherwise       = alignBytes
