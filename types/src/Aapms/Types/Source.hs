-- | 型別註冊表「是從哪一層找到的」這一個事實(G-E002)。
--
-- 只有一個列舉,沒有任何 IO:三層定位的__演算法__住 "Aapms.Types.Loader"
-- (它 re-export 本型別,既有呼叫端不必改 import),但__結果的語彙__是資料。
-- 分家的理由是消費端:@aapms-service@ 的 'Aapms.Service.Types.DoctorView' 要把
-- 它印出來,而 'Aapms.Service.Types' 是型別層的模組——為了一個三值列舉去依賴
-- 一個會讀環境變數與檔案系統的載入器,是把整條 IO 相依鏈掛到型別層上。
module Aapms.Types.Source
  ( RegistrySource (..)
  ) where

-- | 註冊表是從哪一層找到的。
--
-- @doctor@ 要說得出來,找不到時的錯誤訊息也要列得出找過哪裡(G-E002)。
data RegistrySource
  = -- | 'Aapms.Types.Loader.registryEnvVar' 指到的目錄
    FromEnv
  | -- | 執行檔所在目錄底下的 @registry\/@ ——zip 解開就能跑靠的是這一層
    BesideExecutable
  | -- | cabal 的 @data-files@,@cabal install@ 之後才存在
    FromDataDir
  deriving stock (Show, Eq)
