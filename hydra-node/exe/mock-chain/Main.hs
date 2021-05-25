{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

import Cardano.Prelude (async)
import Cardano.Prelude hiding (Option, async, option)
import Data.String
import Data.Text (unpack)
import Hydra.MockZMQChain
import Logging (Severity (Debug), nullTracer, withStdoutTracer)
import Options.Applicative

data Option = Option
  { mode :: ChainMode
  , chainSyncAddress :: String
  , catchUpAddress :: String
  , postTxAddress :: String
  , -- TODO: provide less binary behaviour?
    verbosity :: Verbosity
  }
  deriving (Eq, Show)

data Verbosity = Quiet | Verbose
  deriving (Eq, Show)

data ChainMode = NodeMode | ClientMode | CatchUpMode
  deriving (Eq, Read, Show)

mockChainParser :: Parser Option
mockChainParser =
  Option
    <$> option
      auto
      ( long "mode"
          <> short 'm'
          <> value NodeMode
          <> help "Mode to run mock-chain, one of 'NodeMode', 'CatchUpMode' or 'ClientMode'"
      )
    <*> strOption
      ( long "sync-address"
          <> short 's'
          <> value "tcp://127.0.0.1:56789"
          <> help "The address where clients can connect for syncing transactions"
      )
    <*> strOption
      ( long "catch-up-address"
          <> short 'u'
          <> value "tcp://127.0.0.1:56790"
          <> help "The address where clients can connect for syncing transactions"
      )
    <*> strOption
      ( long "post-address"
          <> short 'p'
          <> value "tcp://127.0.0.1:56791"
          <> help "The address where clients can post transactions"
      )
    <*> flag
      Verbose
      Quiet
      ( long "quiet"
          <> short 'q'
          <> help "Turns off any logging"
      )

mockChainOptions :: ParserInfo Option
mockChainOptions =
  info
    (mockChainParser <**> helper)
    ( fullDesc
        <> progDesc "Starts a mock Chain server"
        <> header "mock-chain - a mock chain server"
    )

main :: IO ()
main = do
  Option{mode, chainSyncAddress, catchUpAddress, postTxAddress, verbosity} <- execParser mockChainOptions
  case mode of
    NodeMode ->
      if verbosity == Verbose
        then
          withStdoutTracer "MockChain" Debug show $
            startChain chainSyncAddress catchUpAddress postTxAddress
        else startChain chainSyncAddress catchUpAddress postTxAddress nullTracer
    CatchUpMode -> catchUpTransactions catchUpAddress print
    ClientMode -> do
      async (runChainSync chainSyncAddress print) >>= link
      forever $ do
        msg <- getLine
        case reads (unpack msg) of
          (tx, "") : _ -> liftIO $ mockChainClient postTxAddress tx
          _ -> print $ "failed to read command: " <> msg
