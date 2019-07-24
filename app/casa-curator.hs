{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Simple tool to push all blobs from the Pantry database to Casa.

module Main where

import           Casa.Client
import           Control.Lens.TH
import           Control.Monad.Trans.Resource
import           Data.Conduit
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import           Data.Text (Text)
import qualified Data.Text as T
import           Options.Applicative
import           Options.Applicative.Simple
import           Pantry
import           Pantry.Internal.Stackage
import           RIO
import           RIO.Orphans
import           System.Environment

data CasaPush =
  CasaPush
    { _casaPushPantry :: !PantryApp
    , _casaPushResourceMap :: !ResourceMap
    }

$(makeLenses ''CasaPush)

instance HasLogFunc CasaPush where logFuncL = casaPushPantry . logFuncL
instance HasResourceMap CasaPush where resourceMapL = casaPushResourceMap

data PushConfig =
  PushConfig
    { configCasaUrl :: String
    }
  deriving (Show)

-- | Command-line config.
pushConfigParser :: Parser PushConfig
pushConfigParser =
  PushConfig <$>
  strOption (long "push-url" <> metavar "URL" <> help "Casa push URL")

data PopulateConfig =
  PopulateConfig
    { populateConfigSnapshot :: Unresolved RawSnapshotLocation
    }

-- | Command-line config.
populateConfigParser :: Parser PopulateConfig
populateConfigParser =
  PopulateConfig <$>
  fmap
    (parseRawSnapshotLocation . T.pack)
    (strOption
       (long "snapshot" <> metavar "SNAPSHOT" <>
        help "Snapshot in usual Stack format (lts-1.1, nightly-...)"))

-- | Main entry point.
main :: IO ()
main = do
  ((), runCmd) <-
    simpleOptions
      "0"
      "casa-curator"
      "casa-curator"
      (pure ())
      (do addCommand "push" "Push all blobs" pushCommand pushConfigParser
          addCommand "status" "Give some stats" (const statusCommand) (pure ())
          addCommand
            "populate"
            "Populate the pantry database"
            populateCommand
            populateConfigParser)
  runCmd

statusCommand :: IO ()
statusCommand =
  runPantryApp
    (do pantryApp <- ask
        storage <- fmap (pcStorage . view pantryConfigL) ask
        withResourceMap
          (\resourceMap ->
             runRIO
               (CasaPush
                  { _casaPushResourceMap = resourceMap
                  , _casaPushPantry = pantryApp
                  })
               (withStorage_
                  storage
                  (do count <- allBlobsCount
                      lift (logInfo ("Blobs in database: " <> display count))))))

populateCommand :: MonadIO m => PopulateConfig -> m ()
populateCommand populateConfig =
  runPantryApp
    (do let unresoledRawSnapshotLocation = populateConfigSnapshot populateConfig
        rawSnapshotLocation <- resolvePaths Nothing unresoledRawSnapshotLocation
        snapshotLocation <- completeSnapshotLocation rawSnapshotLocation
        logSticky "Loading snapshot ..."
        rawSnapshot <- loadSnapshot snapshotLocation
        logStickyDone "Loaded snapshot."
        let total = length (rsPackages rawSnapshot)
        for_
          (zip
             [0 :: Int ..]
             (map rspLocation (M.elems (rsPackages rawSnapshot))))
          (\(i, rawPackageLocationImmutable) -> do
             logSticky
               ("Loading package: " <> display i <> "/" <> display total <> ": " <>
                display rawPackageLocationImmutable)
             loadPackageRaw rawPackageLocationImmutable))

-- | Start pushing.
pushCommand :: MonadIO m => PushConfig -> m ()
pushCommand config =
  runPantryApp
    (do pantryApp <- ask
        storage <- fmap (pcStorage . view pantryConfigL) ask
        withResourceMap
          (\resourceMap ->
             runRIO
               (CasaPush
                  { _casaPushResourceMap = resourceMap
                  , _casaPushPantry = pantryApp
                  })
               (withStorage_
                  storage
                  (do count <- allBlobsCount
                      blobsSink
                        (configCasaUrl config)
                        (allBlobsSource .| stickyProgress count)))))

-- | Output progress of blobs pushed.
stickyProgress ::
     (HasLogFunc env) => Int -> ConduitT i i (ReaderT r (RIO env)) ()
stickyProgress total = go (0 :: Int)
  where
    go i = do
      m <- await
      case m of
        Nothing ->
          lift (lift (logStickyDone ("Pushed " <> display total <> " blobs.")))
        Just v -> do
          let i' = i + 1
          lift
            (lift
               (logSticky
                  ("Pushing blobs: " <> display i' <> "/" <> display total)))
          yield v
          go i'
