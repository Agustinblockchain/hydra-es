{-# LANGUAGE TypeApplications #-}

module Hydra.Chain.Direct.Context where

import Hydra.Prelude

import Data.List ((!!), (\\))
import Hydra.Cardano.Api (
  NetworkId (..),
  NetworkMagic (..),
  PaymentKey,
  SigningKey,
  Tx,
  UTxO,
  VerificationKey,
 )
import Hydra.Chain (HeadParameters (..), OnChainTx (..))
import Hydra.Chain.Direct.ScriptRegistry (genScriptRegistry)
import Hydra.Chain.Direct.State (
  ChainContext (..),
  HeadStateKind (..),
  ObserveTx,
  OnChainHeadState,
  close,
  collect,
  commit,
  fanout,
  getContestationDeadline,
  idleOnChainHeadState,
  initialize,
  observeTx,
 )
import Hydra.ContestationPeriod (ContestationPeriod)
import Hydra.Crypto (HydraKey, generateSigningKey)
import Hydra.Ledger.Cardano (genOneUTxOFor, genTxIn, genUTxOAdaOnlyOfSize, genVerificationKey, renderTx)
import Hydra.Ledger.Cardano.Evaluate (genPointInTime, slotNoFromPOSIXTime)
import Hydra.Party (Party, deriveParty)
import Hydra.Snapshot (ConfirmedSnapshot (..), Snapshot (..), SnapshotNumber, genConfirmedSnapshot)
import Test.QuickCheck (choose, elements, frequency, vector)

-- TODO: Move this to test code as it assumes global knowledge (ctxHydraSigningKeys)

-- | Define some 'global' context from which generators can pick
-- values for generation. This allows to write fairly independent generators
-- which however still make sense with one another within the context of a head.
--
-- For example, one can generate a head's _party_ from that global list, whereas
-- other functions may rely on all parties and thus, we need both generation to
-- be coherent.
data HydraContext = HydraContext
  { ctxVerificationKeys :: [VerificationKey PaymentKey]
  , ctxHydraSigningKeys :: [SigningKey HydraKey]
  , ctxNetworkId :: NetworkId
  , ctxContestationPeriod :: ContestationPeriod
  }
  deriving (Show)

ctxParties :: HydraContext -> [Party]
ctxParties = fmap deriveParty . ctxHydraSigningKeys

ctxHeadParameters ::
  HydraContext ->
  HeadParameters
ctxHeadParameters ctx@HydraContext{ctxContestationPeriod} =
  HeadParameters ctxContestationPeriod (ctxParties ctx)

--
-- Generators
--

-- | Generate a `HydraContext` for a bounded arbitrary number of parties.
--
-- 'maxParties'  sets the upper bound in the number of parties in the Head.
genHydraContext :: Int -> Gen HydraContext
genHydraContext maxParties = choose (1, maxParties) >>= genHydraContextFor

-- | Generate a 'HydraContext' for a given number of parties.
genHydraContextFor :: Int -> Gen HydraContext
genHydraContextFor n = do
  ctxVerificationKeys <- replicateM n genVerificationKey
  ctxHydraSigningKeys <- fmap generateSigningKey <$> vector n
  ctxNetworkId <- Testnet . NetworkMagic <$> arbitrary
  ctxContestationPeriod <- arbitrary
  pure $
    HydraContext
      { ctxVerificationKeys
      , ctxHydraSigningKeys
      , ctxNetworkId
      , ctxContestationPeriod
      }

-- | Pick one of the participants and derive the peer-specific ChainContext from
-- a HydraContext. NOTE: This assumes that 'HydraContext' has same length
-- 'ctxVerificationKeys' and 'ctxHydraSigningKeys'.
pickChainContext :: HydraContext -> Gen ChainContext
pickChainContext ctx = do
  ourIndex <- choose (0, length ctxHydraSigningKeys - 1)
  let ownVerificationKey = ctxVerificationKeys !! ourIndex
      ownParty = deriveParty $ ctxHydraSigningKeys !! ourIndex
  scriptRegistry <- genScriptRegistry
  pure $
    ChainContext
      { networkId = ctxNetworkId
      , peerVerificationKeys = ctxVerificationKeys \\ [ownVerificationKey]
      , ownVerificationKey
      , ownParty
      , scriptRegistry
      }
 where
  HydraContext
    { ctxVerificationKeys
    , ctxHydraSigningKeys
    , ctxNetworkId
    } = ctx

genStIdle ::
  HydraContext ->
  Gen (OnChainHeadState 'StIdle)
genStIdle ctx@HydraContext{ctxVerificationKeys, ctxNetworkId} = do
  ownParty <- elements (ctxParties ctx)
  ownVerificationKey <- elements ctxVerificationKeys
  let peerVerificationKeys = ctxVerificationKeys \\ [ownVerificationKey]
  scriptRegistry <- genScriptRegistry
  pure $ idleOnChainHeadState ctxNetworkId peerVerificationKeys ownVerificationKey ownParty scriptRegistry

genStInitialized ::
  HydraContext ->
  Gen (OnChainHeadState 'StInitialized)
genStInitialized ctx = do
  stIdle <- genStIdle ctx
  seedInput <- genTxIn
  cctx <- pickChainContext ctx
  let initTx = initialize cctx (ctxHeadParameters ctx) seedInput
  pure $ snd $ unsafeObserveTx @_ @ 'StInitialized initTx stIdle

genInitTx ::
  HydraContext ->
  Gen Tx
genInitTx ctx = do
  cctx <- pickChainContext ctx
  initialize cctx (ctxHeadParameters ctx) <$> genTxIn

genCommits ::
  HydraContext ->
  Tx ->
  Gen [Tx]
genCommits ctx initTx = do
  forM (zip (ctxVerificationKeys ctx) (ctxParties ctx)) $ \(vk, p) -> do
    let peerVerificationKeys = ctxVerificationKeys ctx \\ [vk]
    scriptRegistry <- genScriptRegistry
    let stIdle = idleOnChainHeadState (ctxNetworkId ctx) peerVerificationKeys vk p scriptRegistry
    let (_, stInitialized) = unsafeObserveTx @_ @ 'StInitialized initTx stIdle
    utxo <- genCommit
    pure $ unsafeCommit utxo stInitialized

genCommit :: Gen UTxO
genCommit =
  frequency
    [ (1, pure mempty)
    , (10, genVerificationKey >>= genOneUTxOFor)
    ]

genCloseTx :: Int -> Gen (OnChainHeadState 'StOpen, Tx, ConfirmedSnapshot Tx)
genCloseTx numParties = do
  ctx <- genHydraContextFor numParties
  (u0, stOpen) <- genStOpen ctx
  snapshot <- genConfirmedSnapshot 0 u0 (ctxHydraSigningKeys ctx)
  pointInTime <- genPointInTime
  pure (stOpen, close snapshot pointInTime stOpen, snapshot)

genFanoutTx :: Int -> Int -> Gen (OnChainHeadState 'StClosed, Tx)
genFanoutTx numParties numOutputs = do
  ctx <- genHydraContext numParties
  utxo <- genUTxOAdaOnlyOfSize numOutputs
  (_, toFanout, stClosed) <- genStClosed ctx utxo
  let deadlineSlotNo = slotNoFromPOSIXTime (getContestationDeadline stClosed)
  pure (stClosed, fanout toFanout deadlineSlotNo stClosed)

genStOpen ::
  HydraContext ->
  Gen (UTxO, OnChainHeadState 'StOpen)
genStOpen ctx = do
  initTx <- genInitTx ctx
  commits <- genCommits ctx initTx
  (committed, stInitialized) <- executeCommits initTx commits <$> genStIdle ctx
  let collectComTx = collect stInitialized
  pure (fold committed, snd $ unsafeObserveTx @_ @ 'StOpen collectComTx stInitialized)

genStClosed ::
  HydraContext ->
  UTxO ->
  Gen (SnapshotNumber, UTxO, OnChainHeadState 'StClosed)
genStClosed ctx utxo = do
  (u0, stOpen) <- genStOpen ctx
  confirmed <- arbitrary
  let (sn, snapshot, toFanout) = case confirmed of
        cf@InitialSnapshot{snapshot = s} ->
          ( 0
          , cf{snapshot = s{utxo = u0}}
          , u0
          )
        cf@ConfirmedSnapshot{snapshot = s} ->
          ( number s
          , cf{snapshot = s{utxo = utxo}}
          , utxo
          )
  pointInTime <- genPointInTime
  let closeTx = close snapshot pointInTime stOpen
  pure (sn, toFanout, snd $ unsafeObserveTx @_ @ 'StClosed closeTx stOpen)

--
-- Here be dragons
--

unsafeObserveTx ::
  forall st st'.
  (ObserveTx st st', HasCallStack) =>
  Tx ->
  OnChainHeadState st ->
  (OnChainTx Tx, OnChainHeadState st')
unsafeObserveTx tx st =
  fromMaybe (error hopefullyInformativeMessage) (observeTx @st @st' tx st)
 where
  hopefullyInformativeMessage =
    "unsafeObserveTx:"
      <> "\n  From:\n    "
      <> show st
      <> "\n  Via:\n    "
      <> renderTx tx

unsafeCommit ::
  HasCallStack =>
  UTxO ->
  OnChainHeadState 'StInitialized ->
  Tx
unsafeCommit u =
  either (error . show) id . commit u

executeCommits ::
  Tx ->
  [Tx] ->
  OnChainHeadState 'StIdle ->
  ([UTxO], OnChainHeadState 'StInitialized)
executeCommits initTx commits stIdle =
  (utxo, stInitialized')
 where
  (_, stInitialized) = unsafeObserveTx @_ @ 'StInitialized initTx stIdle
  (utxo, stInitialized') = flip runState stInitialized $ do
    forM commits $ \commitTx -> do
      st <- get
      let (event, st') = unsafeObserveTx @_ @ 'StInitialized commitTx st
      put st'
      pure $ case event of
        OnCommitTx{committed} -> committed
        _ -> mempty
