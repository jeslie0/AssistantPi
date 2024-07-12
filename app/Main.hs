module Main where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket)
import Control.Monad (void, when)
import Data.ByteArray (ByteArrayAccess (..))
import Data.ByteString qualified as B
import Data.ByteString.Internal qualified as BI
import Data.Int (Int8)
import Foreign (pokeByteOff)
import Foreign.Ptr (Ptr)
import Loop (forLoop)
import Sound.OpenAL (genObjectName, ($=))
import Sound.OpenAL.AL qualified as AL
import Sound.OpenAL.ALC qualified as ALC
import System.Random (randomIO)

-- * Constants

-- Establish constants used through the module.

-- | The sampling frequency, or sample rate.
frequency :: Float
frequency =
  44100.0

-- | The length of time (in seconds) that a buffer should be played
--  for.
bufferTimeSeconds :: Float
bufferTimeSeconds =
  0.5

-- | The length of time (in microseconds) that a buffer should be
--  played for.
bufferTimeMicroSeconds :: Int
bufferTimeMicroSeconds =
  round $ bufferTimeSeconds * 1000000

-- | The size of a buffer, calculated from the sampling frequency and
--  the buffer time.
bufferSize :: Int
bufferSize =
  round $ frequency * fromIntegral bufferTimeMicroSeconds / oneSecond
  where
    oneSecond = 1000000

-- * Buffer creation

-- | Create a bytestring of random noise, to be used as a buffer.
makeNoisyBytes :: IO B.ByteString
makeNoisyBytes =
  BI.create bufferSize (filler bufferSize)

-- | Given a pointer to a buffer and a length, fill the buffer with
-- random noise.
filler :: Int -> Ptr a -> IO ()
filler n ptr =
  forLoop 0 (< n) (+ 1) $ \m -> randomIO @Int8 >>= pokeByteOff ptr m

-- | Create a new noisy buffer.
createNoisyBuffer :: IO AL.Buffer
createNoisyBuffer = do
  buffer :: AL.Buffer <- genObjectName
  updateNoisyBuffer buffer
  return buffer

-- | Modify the given buffer to regenerate it with noise.
updateNoisyBuffer :: AL.Buffer -> IO ()
updateNoisyBuffer buffer = do
  !bytes <- makeNoisyBytes
  withByteArray bytes $ \ptr ->
    let bufferDataSTV =
          AL.bufferData buffer

        !newMemRegion =
          AL.MemoryRegion ptr $ fromIntegral (B.length bytes)

        -- Buffer data is expected to consist of bytes, which is why
        -- we use Mono8 here. We could use 16 bit sounds, but for
        -- something this simple, there really is no need.
        !newBufferData =
          AL.BufferData newMemRegion AL.Mono8 frequency
     in bufferDataSTV $= newBufferData

-- | A control loop to keep checking and updating the noise source.
loop :: AL.Source -> IO ()
loop source = do
  -- We pause execution for less time than a buffer is being played for.
  threadDelay $ bufferTimeMicroSeconds `div` 2
  state <- AL.sourceState source
  if state == AL.Stopped
    then return ()
    else do
      processed <- AL.buffersProcessed source
      when (processed >= 1) $ do
        bufs <- AL.unqueueBuffers source processed
        let buf = head bufs
        updateNoisyBuffer buf
        AL.queueBuffers source [buf]
      loop source

main :: IO ()
main = do
  bracket
    (ALC.openDevice Nothing)
    (maybe (return ()) $ \device -> void (ALC.closeDevice device))
    $ \maybeDevice -> do
      case maybeDevice of
        Nothing -> return ()
        Just device -> do
          maybeContext <- ALC.createContext device streamAttributes
          ALC.currentContext $= maybeContext

          -- Clear the error codes.
          _errors <- AL.alErrors

          -- Create a new source for the sounds.
          source :: AL.Source <- genObjectName

          -- Create two buffers that will be reused in the sound
          -- generation. When one buffer is finished, it gets updated and
          -- added to the back of the queue.
          !buffer1 <- createNoisyBuffer
          !buffer2 <- createNoisyBuffer

          -- Queue the two buffers.
          AL.queueBuffers source [buffer1, buffer2]

          -- Start playing the audio in a separate thread.
          AL.play [source]

          -- Start looping and updating the source when required.
          loop source
          where
            streamAttributes =
              [ ALC.Frequency 44100,
                ALC.MonoSources 1,
                ALC.StereoSources 0
              ]
