{-# OPTIONS_GHC -fno-warn-orphans #-}

module Test.Arbitrary () where

import Control.Applicative ((<$>), (<*>))
import LIO.DCLabel (DCLabel(DCLabel), (%%), (/\), (\/), CNF, toCNF)
import Test.QuickCheck (Arbitrary(..), sized, vectorOf, elements, Gen)

import qualified Data.ByteString as SBS

import Thentos.Types (HashedSecret, ThentosLabel(..), ThentosClearance(..))

import Test.Util


instance Arbitrary (HashedSecret a) where
    arbitrary = encryptTestSecret . SBS.pack <$> arbitrary

instance Arbitrary ThentosLabel where
    arbitrary = ThentosLabel <$> arbitrary

instance Arbitrary ThentosClearance where
    arbitrary = ThentosClearance <$> arbitrary

instance Arbitrary DCLabel where
    arbitrary = DCLabel <$> arbitrary <*> arbitrary
    shrink (DCLabel s i) = [s %% False, s %% True, False %% i, True %% i]

instance Arbitrary CNF where
    arbitrary = sized $ \ l -> vectorOf l (elements principals) >>= combine
      where
        combine :: [String] -> Gen CNF
        combine []     = toCNF <$> (arbitrary :: Gen Bool)
        combine (p:ps) = do
            o   <- arbitrary
            ps' <- combine ps
            let op = if o then (/\) else (\/)
            return $ p `op` ps'

-- | 25 most common adjectives according to the Oxford English
-- Dictionary.
principals :: [String]
principals =
    "good" : "new" : "first" : "last" : "long" : "great" : "little" :
    "own" : "other" : "old" : "right" : "big" : "high" : "different" :
    "small" : "large" : "next" : "early" : "young" : "important" :
    "few" : "public" : "bad" : "same" : "able" :
    []
