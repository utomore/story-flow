-- | F001:'Aapms.Workspace.Location' 的 'hubLocation'(LAW-1\/EX-1-EX-3)與三個純衍生
-- 路徑 'configPath' \/ 'thumbCacheDir' \/ 'thumbCachePath'(LAW-2\/LAW-3\/EX-19\/EX-20)。
--
-- __spec 對照__(@.design\/subsystems\/workspace\/features\/F001-hub-registry.md@):
--
-- @
-- LAW-1  hubLocation 的兩層解析(AAPMS_HOME 非空 -> FromEnv;否則 FromPlatformDefault) -> prop_LAW1_*
-- LAW-2  configPath / thumbCacheDir 是純衍生、與 hlSource 無關                        -> prop_LAW2
-- LAW-3  thumbCachePath 的分片與前綴                                                  -> prop_LAW3
-- EX-1  AAPMS_HOME = "D:\\hub"                                                       -> test_hub_location_from_env
-- EX-2  AAPMS_HOME 未設                                                              -> test_hub_location_platform_default
-- EX-3  AAPMS_HOME = ""                                                              -> test_hub_location_empty_env_falls_back
-- EX-19 configPath / thumbCacheDir 的字面例子                                        -> test_config_path_derivation
-- EX-20 thumbCachePath 的字面例子                                                    -> test_thumb_cache_path_shard_and_prefix
-- @
module Aapms.Workspace.LocationSpec (spec) where

import Control.Monad.IO.Class (liftIO)
import Data.List (isPrefixOf)
import qualified Data.Text as T
import Hedgehog (forAll, (===))
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

import Aapms.Core.Asset (Sha256 (..))
import Aapms.Workspace.Fixtures
import Aapms.Workspace.Location
import Aapms.Workspace.Types (HubLocation (..), HubSource (..))

import System.Directory (makeAbsolute)
import System.FilePath (isAbsolute, takeFileName, (</>))

aapmsHomeVar :: String
aapmsHomeVar = "AAPMS_HOME"

spec :: Spec
spec = describe "F001 Aapms.Workspace.Location" $ do
  describe "LAW-1 / EX-1-EX-3: hubLocation 的兩層解析" $ do
    it "test_hub_location_from_env: AAPMS_HOME 非空(無前後空白)時 FromEnv,hlPath 是它的絕對化" $
      hedgehog $ do
        s <- forAll genNonBlankEnvValue
        loc <- liftIO (withEnv [(aapmsHomeVar, Just (T.unpack s))] hubLocation)
        expected <- liftIO (makeAbsolute (T.unpack s))
        hlSource loc === FromEnv
        hlPath loc === expected

    it "LAW-1(較嚴格): 前後帶空白但去除空白後非空,hlPath 仍是「原始 s」的絕對化(不是先去空白)" $
      hedgehog $ do
        s <- forAll genPaddedNonBlank
        loc <- liftIO (withEnv [(aapmsHomeVar, Just (T.unpack s))] hubLocation)
        expected <- liftIO (makeAbsolute (T.unpack s))
        hlSource loc === FromEnv
        hlPath loc === expected

    it "test_hub_location_empty_env_falls_back: AAPMS_HOME 全空白(含空字串)時視同未設,走平台預設" $
      hedgehog $ do
        s <- forAll genBlankEnvValue
        loc <- liftIO (withEnv [(aapmsHomeVar, Just (T.unpack s))] hubLocation)
        hlSource loc === FromPlatformDefault

    it "test_hub_location_platform_default: AAPMS_HOME 未設時走平台預設" $ do
      loc <- withEnv [(aapmsHomeVar, Nothing)] hubLocation
      hlSource loc `shouldBe` FromPlatformDefault

    it "EX-1: AAPMS_HOME = \"D:\\\\hub\" -> FromEnv,hlPath 是它的絕對化" $ do
      loc <- withEnv [(aapmsHomeVar, Just "D:\\hub")] hubLocation
      hlSource loc `shouldBe` FromEnv
      expected <- makeAbsolute "D:\\hub"
      hlPath loc `shouldBe` expected

    it "EX-2: AAPMS_HOME 未設 -> FromPlatformDefault,hlPath 絕對且以 aapms 結尾" $ do
      loc <- withEnv [(aapmsHomeVar, Nothing)] hubLocation
      hlSource loc `shouldBe` FromPlatformDefault
      hlPath loc `shouldSatisfy` isAbsolute
      takeFileName (hlPath loc) `shouldBe` "aapms"

    it "EX-3: AAPMS_HOME = \"\" 同 EX-2(空字串視同未設)" $ do
      loc <- withEnv [(aapmsHomeVar, Just "")] hubLocation
      hlSource loc `shouldBe` FromPlatformDefault
      takeFileName (hlPath loc) `shouldBe` "aapms"

    it "兩種情形的 hlPath 恆為絕對路徑" $ do
      envLoc <- withEnv [(aapmsHomeVar, Just "rel-hub-dir")] hubLocation
      defLoc <- withEnv [(aapmsHomeVar, Nothing)] hubLocation
      hlPath envLoc `shouldSatisfy` isAbsolute
      hlPath defLoc `shouldSatisfy` isAbsolute

  describe "LAW-2 / EX-19: configPath / thumbCacheDir 是純衍生、與 hlSource 無關" $ do
    it "test_config_path_derivation: configPath == hlPath </> config.toml,兩種 hlSource 結果相同" $
      hedgehog $ do
        dir <- forAll genAbsPath
        let locEnv = HubLocation dir FromEnv
            locDef = HubLocation dir FromPlatformDefault
        configPath locEnv === dir </> "config.toml"
        configPath locDef === dir </> "config.toml"

    it "test_thumb_cache_dir_derivation: thumbCacheDir == hlPath </> cache </> thumbs,與 hlSource 無關" $
      hedgehog $ do
        dir <- forAll genAbsPath
        let locEnv = HubLocation dir FromEnv
            locDef = HubLocation dir FromPlatformDefault
        thumbCacheDir locEnv === dir </> "cache" </> "thumbs"
        thumbCacheDir locDef === dir </> "cache" </> "thumbs"

    it "EX-19: loc = HubLocation \"C:\\\\hub\" FromEnv 的字面例子" $ do
      let loc = HubLocation "C:\\hub" FromEnv
      configPath loc `shouldBe` "C:\\hub\\config.toml"
      thumbCacheDir loc `shouldBe` "C:\\hub\\cache\\thumbs"

  describe "LAW-3 / EX-20: thumbCachePath 的分片與前綴" $ do
    it
      "test_thumb_cache_path_shard_and_prefix: 對任意 64 位十六進位字串,thumbCachePath \
      \的分片是前兩碼、以 thumbCacheDir 為前綴"
      $ hedgehog $ do
        dir <- forAll genAbsPath
        h <- forAll genHex64
        let loc = HubLocation dir FromEnv
            result = thumbCachePath loc (Sha256 h)
            expected = thumbCacheDir loc </> T.unpack (T.take 2 h) </> (T.unpack h <> ".png")
        result === expected
        (thumbCacheDir loc `isPrefixOf` result) === True

    it "EX-20: thumbCachePath 的字面例子" $ do
      let loc = HubLocation "C:\\hub" FromEnv
          h = "3f9c1d20" <> T.replicate 56 "0"
      thumbCachePath loc (Sha256 h)
        `shouldBe` "C:\\hub\\cache\\thumbs\\3f\\" <> T.unpack h <> ".png"
