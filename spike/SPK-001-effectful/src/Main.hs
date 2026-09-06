{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

module Main (main) where

import Data.IORef
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)

import Effectful
import Effectful.Dispatch.Dynamic
import Effectful.Error.Static
import Effectful.State.Static.Local
import Effectful.TH (makeEffect)

-- 1. Custom dynamic effect --------------------------------------------------

data Index :: Effect where
  PutRow  :: Text -> Int -> Index m ()
  GetRow  :: Text -> Index m (Maybe Int)
  AllRows :: Index m [(Text, Int)]

type instance DispatchOf Index = Dynamic

makeEffect ''Index

-- 2. Pure interpreter over Effectful.State.Static.Local ---------------------

runIndexPure :: forall es a. Eff (Index : es) a -> Eff es a
runIndexPure = reinterpret (evalState (Map.empty :: Map Text Int)) $ \_ -> \case
  PutRow k v -> modify (Map.insert k v)
  GetRow k -> gets (Map.lookup k)
  AllRows -> gets Map.toList

-- 3. IO interpreter over an external IORef -----------------------------------

runIndexIO :: IOE :> es => IORef (Map Text Int) -> Eff (Index : es) a -> Eff es a
runIndexIO ref = interpret $ \_ -> \case
  PutRow k v -> liftIO $ modifyIORef' ref (Map.insert k v)
  GetRow k -> liftIO $ Map.lookup k <$> readIORef ref
  AllRows -> liftIO $ Map.toList <$> readIORef ref

-- Sample program shared between interpreters ---------------------------------

program :: Index :> es => Eff es [(Text, Int)]
program = do
  putRow "a" 1
  putRow "b" 2
  _ <- getRow "a"
  allRows

pureProgram :: Eff '[Index] [(Text, Int)]
pureProgram = program

-- 4. Error effect composed with Index in a pure program ----------------------

errorProgram :: (Index :> es, Error String :> es) => Eff es Int
errorProgram = do
  putRow "x" 10
  mv <- getRow "y"
  case mv of
    Just v -> pure v
    Nothing -> throwError "not found"

-- 5. main: assert pure and IO interpreters agree ------------------------------

main :: IO ()
main = do
  let pureResult = runPureEff (runIndexPure pureProgram)
  putStrLn $ "pure result: " ++ show pureResult

  ref <- newIORef Map.empty
  ioResult <- runEff (runIndexIO ref program)
  putStrLn $ "io result:   " ++ show ioResult

  if pureResult == ioResult
    then putStrLn "MATCH: pure and IO interpreters agree"
    else error "MISMATCH: pure and IO interpreters disagree"

  let errResult =
        runPureEff . runErrorNoCallStack @String . runIndexPure $ errorProgram
  putStrLn $ "error program result: " ++ show errResult

  case errResult of
    Left "not found" -> putStrLn "OK: Error effect composed with Index as expected"
    other -> error $ "UNEXPECTED error program result: " ++ show other
