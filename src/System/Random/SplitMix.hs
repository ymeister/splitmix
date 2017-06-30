-- |
-- /SplitMix/ is a splittable pseudorandom number generator (PRNG) that is quite fast.
--
-- Guy L. Steele, Jr., Doug Lea, and Christine H. Flood. 2014.  Fast splittable pseudorandom number generators. /In Proceedings of the 2014 ACM International Conference on Object Oriented Programming Systems Languages & Applications/ (OOPSLA '13). ACM, New York, NY, USA, 453-472. DOI: <https://doi.org/10.1145/2660193.2660195>
{-# LANGUAGE Trustworthy #-}
module System.Random.SplitMix (
    SMGen,
    nextWord64,
    nextInt,
    nextDouble,
    splitSMGen,
    -- * Initialisation
    mkSMGen,
    seedSMGen,
    initSMGen,
    newSMGen,
    ) where

import Data.Bits (popCount, shiftL, shiftR, xor, (.|.))
import Data.Word (Word64, Word32)
import Data.IORef (IORef, atomicModifyIORef, newIORef)
import Data.Time.Clock.POSIX (getPOSIXTime)
import System.CPUTime (getCPUTime, cpuTimePrecision)
import System.IO.Unsafe (unsafePerformIO)

import qualified System.Random as R

-------------------------------------------------------------------------------
-- Generator
-------------------------------------------------------------------------------

-- | SplitMix generator state.
data SMGen = SMGen
    { _seed  :: !Word64
    , _gamma :: !Word64  -- ^ always odd
    }
  deriving Show

-------------------------------------------------------------------------------
-- Operations
-------------------------------------------------------------------------------

-- | Generate a 'Word64'.
nextWord64 :: SMGen -> (Word64, SMGen)
nextWord64 (SMGen seed gamma) = (mix64 seed', SMGen seed' gamma)
  where
    seed' = seed + gamma

-- Here, and in splitSMGen, "inlining" of nextSeed is worth doing.
-- I looked at the Core.
{-
nextWord64 :: SMGen -> (Word64, SMGen)
nextWord64 g0 = (mix64 x, g1)
  where
    (x, g1) = nextSeed g0
-}

-- | Generate an 'Int'.
nextInt :: SMGen -> (Int, SMGen)
nextInt g = case nextWord64 g of
    (w64, g') -> (fromIntegral w64, g')

-- | Generate a 'Double' in @[0, 1)@ range.
nextDouble :: SMGen -> (Double, SMGen)
nextDouble g = case nextWord64 g of
    (w64, g') -> (fromIntegral (w64 `shiftR` 11) * doubleUlp, g')

-- | Split a generator into a two uncorrelated generators.
splitSMGen :: SMGen -> (SMGen, SMGen)
splitSMGen (SMGen seed gamma) =
    (SMGen seed'' gamma, SMGen (mix64 seed') (mixGamma seed''))
  where
    seed'  = seed + gamma
    seed'' = seed' + gamma

{-
splitSMGen :: SMGen -> (SMGen, SMGen)
splitSMGen g0 = (g2, SMGen (mix64 x) (mixGamma y))
  where
    (x, g1) = nextSeed g0
    (y, g2) = nextSeed g1
-}

-------------------------------------------------------------------------------
-- Algorithm
-------------------------------------------------------------------------------

goldenGamma :: Word64
goldenGamma = 0x9e3779b97f4a7c15

doubleUlp :: Double
doubleUlp =  1.0 / fromIntegral (1 `shiftL` 53 :: Word64)

{-
nextSeed :: SMGen -> (Word64, SMGen)
nextSeed (SMGen seed gamma) = (seed', SMGen seed' gamma)
  where
    seed' = seed + gamma
-}

mix64 :: Word64 -> Word64
mix64 z0 =
    let z1 = shiftXorMultiply 33 0xc4ceb9fe1a85ec53 z0
        z2 = shiftXorMultiply 33 0xff51afd7ed558ccd z1
        z3 = shiftXor 33 z2
    in z3

mix64variant13 :: Word64 -> Word64
mix64variant13 z0 =
    let z1 = shiftXorMultiply 30 0xbf58476d1ce4e5b9 z0
        z2 = shiftXorMultiply 27 0x94d049bb133111eb z1
        z3 = shiftXor 31 z2
    in z3

mixGamma :: Word64 -> Word64
mixGamma z0 =
    let z1 = mix64variant13 z0 .|. 1
        n  = popCount (z1 `xor` (z1 `shiftR` 1))
    in if n >= 24
        then z1 `xor` 0xaaaaaaaaaaaaaaaa
        else z1

shiftXor :: Int -> Word64 -> Word64
shiftXor n w = w `xor` (w `shiftR` n)

shiftXorMultiply :: Int -> Word64 -> Word64 -> Word64
shiftXorMultiply n k w = shiftXor n w * k

-------------------------------------------------------------------------------
-- Initialisation
-------------------------------------------------------------------------------

-- | Create 'SMGen' using seed and gamma.
seedSMGen
    :: Word64 -- ^ seed
    -> Word64 -- ^ gamma
    -> SMGen
seedSMGen seed gamma = SMGen seed (gamma .|. 1)

-- | Preferred way to deterministically construct 'SMGen'.
mkSMGen :: Word64 -> SMGen
mkSMGen s = SMGen (mix64 s) (mixGamma (s + goldenGamma))

-- | Initialize 'SMGen' using system time.
initSMGen :: IO SMGen
initSMGen = fmap mkSMGen mkSeedTime

-- | Derive a new generator instance from the global 'SMGen' using 'splitSMGen'.
newSMGen :: IO SMGen
newSMGen = atomicModifyIORef theSMGen splitSMGen

theSMGen :: IORef SMGen
theSMGen = unsafePerformIO $ initSMGen >>= newIORef
{-# NOINLINE theSMGen #-}

mkSeedTime :: IO Word64
mkSeedTime = do
    now <- getPOSIXTime
    cpu <- getCPUTime
    let lo = truncate now :: Word32
        hi = fromIntegral (cpu `div` cpuTimePrecision) :: Word32
    return $ fromIntegral hi `shiftL` 32 .|. fromIntegral lo

-------------------------------------------------------------------------------
-- System.Random
-------------------------------------------------------------------------------

instance R.RandomGen SMGen where
    next = nextInt
    split = splitSMGen
