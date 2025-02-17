module Hydra.TUI.Options where

import Hydra.Prelude (
  Applicative ((<*>)),
  FilePath,
  Semigroup ((<>)),
  (<$>),
 )

import Hydra.Cardano.Api (NetworkId)
import Hydra.Network (Host (Host))
import Hydra.Options (networkIdParser)
import Options.Applicative (
  Parser,
  auto,
  help,
  long,
  metavar,
  option,
  short,
  showDefault,
  strOption,
  value,
 )

data Options = Options
  { hydraNodeHost :: Host
  , cardanoNodeSocket :: FilePath
  , cardanoNetworkId :: NetworkId
  , cardanoSigningKey :: FilePath
  }

parseOptions :: Parser Options
parseOptions =
  Options
    <$> parseNodeHost
    <*> parseCardanoNodeSocket
    <*> networkIdParser
    <*> parseCardanoSigningKey

parseCardanoNodeSocket :: Parser FilePath
parseCardanoNodeSocket =
  strOption
    ( long "node-socket"
        <> metavar "FILE"
        <> help "The path to the Cardano node domain socket for client communication."
        <> value "node.socket"
        <> showDefault
    )

parseNodeHost :: Parser Host
parseNodeHost =
  option
    auto
    ( long "connect"
        <> short 'c'
        <> help "Hydra-node to connect to in the form of <host>:<port>"
        <> value (Host "0.0.0.0" 4001)
        <> showDefault
    )

parseCardanoSigningKey :: Parser FilePath
parseCardanoSigningKey =
  strOption
    ( long "cardano-signing-key"
        <> short 'k'
        <> metavar "FILE"
        <> help "The path to the signing key file used for selecting, committing  UTxO and signing off-chain transactions. This file used the same 'Envelope' format than cardano-cli."
        <> value "me.sk"
        <> showDefault
    )
