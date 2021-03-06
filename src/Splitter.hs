{-# LANGUAGE RecordWildCards #-}
{-# Language QuasiQuotes #-}
{-# Language GADTs #-}
{-# Language OverloadedStrings #-}
{-# Language LambdaCase #-}
module Splitter where

import Syntax
import RefinedAst
import ErrM
import Data.Text (Text, pack, unpack)
import Data.List
import qualified Data.List.NonEmpty as NonEmpty
import Data.Maybe
import Data.ByteString hiding (pack, unpack, intercalate, foldr, concat, head, tail)
import qualified Data.Text as Text
import Parse
import Data.Bifunctor
import EVM (VM, ContractCode)
import EVM.Types
import EVM.SymExec (verify, Precondition, Postcondition)

import EVM.Solidity (SolcContract(..), StorageItem(..), SlotType(..))
import Control.Monad
import Data.Map.Strict (Map) -- abandon in favor of [(a,b)]?
import qualified Data.Map.Strict as Map -- abandon in favor of [(a,b)]?

-- Transforms a RefinedSyntax.Behaviour
-- to a k spec.

cell :: String -> String -> String
cell key value = "<" <> key <> "> " <> value <> " </" <> key <> "> \n"

(|-) = cell

infix 7 |-

kStatus :: Mode -> String
kStatus Pass = "EVMC_SUCCESS"
kStatus Fail = "FAILURE:EndStatusCode"

type KSpec = String


getContractName :: Text -> String
getContractName = unpack . Text.concat . Data.List.tail . Text.splitOn ":"


data KOptions =
  KOptions {
    gasExprs :: Map Id String,
    storage :: Maybe String,
    extractbin :: Bool
    }
  

makekSpec :: Map Text SolcContract -> KOptions -> Behaviour -> Err (String, String)
makekSpec sources kOpts behaviour =
  let this = _contract behaviour
      names = Map.fromList $ fmap (\(a, b) -> (getContractName a, b)) (Map.toList sources)
      hasLayout = Map.foldr ((&&) . isJust . _storageLayout) True sources
  in
    if hasLayout then do
      accounts <- forM (_contracts behaviour)
         (\c ->
            errMessage
            (nowhere, "err: " <> show c <> "Bytecode not found\nSources available: " <> show (Map.keys sources))
            (Map.lookup c names))
      thisSource <- errMessage
            (nowhere, "err: " <> show this <> "Bytecode not found\nSources available: " <> show (Map.keys sources))
            (Map.lookup this names)

      return $ mkTerm thisSource names behaviour

    else Bad (nowhere, "No storagelayout found")

kCalldata :: Interface -> String
kCalldata (Interface a b) =
  "#abiCallData("
  <> show a <> ", "
  <> (case b of
       [] -> ".IntList"
       args -> 
         intercalate ", " (fmap (\(Decl typ varname) -> "#" <> show typ <> "(" <> kVar varname <> ")") args))
  <> ")"

getId :: Either StorageLocation StorageUpdate -> Id
getId (Right (IntUpdate a _)) = getId' a
getId (Right (BoolUpdate a _)) = getId' a
getId (Right (BytesUpdate a _)) = getId' a
getId (Left (IntLoc a)) = getId' a
getId (Left (BoolLoc a)) = getId' a
getId (Left (BytesLoc a)) = getId' a

getId' :: TStorageItem a -> Id
getId' (DirectInt id) = id
getId' (DirectBool id) = id
getId' (DirectBytes id) = id
getId' (MappedInt id _) = id
getId' (MappedBool id _) = id
getId' (MappedBytes id _) = id


kstorageName :: TStorageItem a -> String
kstorageName (DirectInt id)    = kVar id
kstorageName (DirectBool id)   = kVar id
kstorageName (DirectBytes id)  = kVar id
kstorageName (MappedInt id ixs) = kVar id <> "_" <> intercalate "_" (NonEmpty.toList $ fmap kExpr ixs)
kstorageName (MappedBool id ixs) = kVar id <> "_" <> intercalate "_" (NonEmpty.toList $ fmap kExpr ixs)
kstorageName (MappedBytes id ixs) = kVar id <> "_" <> intercalate "_" (NonEmpty.toList $ fmap kExpr ixs)

kVar :: Id -> String
kVar a = (unpack . Text.toUpper . pack $ [head a]) <> (tail a)

kAbiEncode :: Maybe ReturnExp -> String
kAbiEncode Nothing = ".ByteArray"
kAbiEncode (Just (ExpInt a)) = "#enc(#uint256" <> kExprInt a <> ")"
kAbiEncode (Just (ExpBool a)) = ".ByteArray"
kAbiEncode (Just (ExpBytes a)) = ".ByteArray"


kExpr :: ReturnExp -> String
kExpr (ExpInt a) = kExprInt a
kExpr (ExpBool a) = kExprBool a
-- kExpr (ExpBytes a)


kExprInt :: Exp Int -> String
kExprInt (Add a b) = "(" <> kExprInt a <> " +Int " <> kExprInt b <> ")"
kExprInt (Sub a b) = "(" <> kExprInt a <> " -Int " <> kExprInt b <> ")"
kExprInt (Mul a b) = "(" <> kExprInt a <> " *Int " <> kExprInt b <> ")"
kExprInt (Div a b) = "(" <> kExprInt a <> " /Int " <> kExprInt b <> ")"
kExprInt (Mod a b) = "(" <> kExprInt a <> " modInt " <> kExprInt b <> ")"
kExprInt (Exp a b) = "(" <> kExprInt a <> " ^Int " <> kExprInt b <> ")"
kExprInt (LitInt a) = show a
kExprInt (IntVar a) = kVar a
kExprInt (IntEnv a) = show a
kExprInt (TEntry a) = kstorageName a
kExprInt v = error ("Internal error: TODO kExprInt of " <> show v)


kExprBool :: Exp Bool -> String
kExprBool (And a b) = "(" <> kExprBool a <> " andBool\n " <> kExprBool b <> ")"
kExprBool (Or a b) = "(" <> kExprBool a <> " orBool " <> kExprBool b <> ")"
kExprBool (Impl a b) = "(" <> kExprBool a <> " impliesBool " <> kExprBool b <> ")"
kExprBool (Eq a b) = "(" <> kExprInt a <> " ==Int " <> kExprInt b <> ")"

kExprBool (NEq a b) = "(" <> kExprInt a <> " =/=Int " <> kExprInt b <> ")"
kExprBool (Neg a) = "notBool (" <> kExprBool a <> ")"
kExprBool (LE a b) = "(" <> kExprInt a <> " <Int " <> kExprInt b <> ")"
kExprBool (LEQ a b) = "(" <> kExprInt a <> " <=Int " <> kExprInt b <> ")"
kExprBool (GE a b) = "(" <> kExprInt a <> " >Int " <> kExprInt b <> ")"
kExprBool (GEQ a b) = "(" <> kExprInt a <> " >=Int " <> kExprInt b <> ")"
kExprBool (LitBool a) = show a
kExprBool (BoolVar a) = kVar a
kExprBool v = error ("Internal error: TODO kExprBool of " <> show v)

fst' (x, _, _) = x
snd' (_, y, _) = y
trd' (_, _, z) = z

kStorageEntry :: Map Text StorageItem -> Either StorageLocation StorageUpdate -> (String, (Int, String, String))
kStorageEntry storageLayout update =
  let (loc, offset) = kSlot update $
        fromMaybe
         (error "Internal error: storageVar not found, please report this error")
         (Map.lookup (pack (getId update)) storageLayout)
  in case update of
       Right (IntUpdate a b) -> (loc, (offset, kstorageName a, kExprInt b))
       Left (IntLoc a) -> (loc, (offset, kstorageName a, kstorageName a))
       v -> error $ "Internal error: TODO kStorageEntry: " <> show v
--  BoolUpdate (TStorageItem Bool) c -> 
--  BytesUpdate (TStorageItem ByteString) d ->  (Exp ByteString)

--packs entries packed in one slot
normalize :: Bool -> [(String, (Int, String, String))] -> String
normalize pass entries = foldr (\a acc -> case a of
                              (loc, [(_, pre, post)]) -> loc <> " |-> (" <> pre <> " => " <> if pass then post else "_" <> ")\n" <> acc
                              (loc, items) -> let (offsets, pres, posts) = unzip3 items
                                              in loc <> " |-> ( #packWords(" <> showSList (fmap show offsets) <> ", "
                                                     <> showSList pres <> ") "
                                                     <> " => " <> if pass
                                                                  then "#packWords(" <> showSList (fmap show offsets) <> ", " <> showSList posts <> ")"
                                                                  else "_"
                                                     <> ")\n" <> acc)
                                 "\n"
                      (group entries)
  where group :: [(String, (Int, String, String))] -> [(String, [(Int, String, String)])]
        group a = Map.toList (foldr (\(slot, (offset, pre, post)) acc -> Map.insertWith (<>) slot [(offset, pre, post)] acc) mempty a)
        showSList :: [String] -> String
        showSList = intercalate " "

kSlot :: Either StorageLocation StorageUpdate -> StorageItem -> (String, Int)
kSlot update StorageItem{..} = case _type of
  (StorageValue _) -> (show _slot, _offset)
  (StorageMapping _ _) -> case update of
      Right (IntUpdate (MappedInt _ ixs) _) -> ("#hashedLocation(\"Solidity\", " <> show _slot <> ", " <> intercalate " " (fmap kExpr (NonEmpty.toList ixs)) <> ")", _offset)
      Right (BoolUpdate (MappedBool _ ixs) _) -> ("#hashedLocation(\"Solidity\", " <> show _slot <> ", " <> intercalate " " (fmap kExpr (NonEmpty.toList ixs)) <> ")", _offset)
      Right (BytesUpdate (MappedBytes _ ixs) _) -> ("#hashedLocation(\"Solidity\", " <> show _slot <> ", " <> intercalate " " (fmap kExpr (NonEmpty.toList ixs)) <> ")", _offset)
      _ -> error "internal error: kSlot. Please report"


kAccount :: Bool -> Id -> SolcContract -> [Either StorageLocation StorageUpdate] -> String
kAccount pass name source updates =
  "account" |- ("\n"
   <> "acctID" |- kVar name
   <> "balance" |- (kVar name <> "_balance") -- needs to be constrained to uint256
   <> "code" |- (kByteStack (_runtimeCode source))
   <> "storage" |- (normalize pass ( fmap (kStorageEntry (fromJust (_storageLayout source))) updates) <> "\n.Map")
   <> "origStorage" |- ".Map" -- need to be generalized once "kStorageEntry" is implemented
   <> "nonce" |- "_"
      )

kByteStack :: ByteString -> String
kByteStack bs = "#parseByteStack(\"" <> show (ByteStringS bs) <> "\")"

defaultConditions :: String -> String
defaultConditions acct_id =
    "#rangeAddress(" <> acct_id <> ")\n" <>
    "andBool " <> acct_id <> " =/=Int 0\n" <>
    "andBool " <> acct_id <> " >Int 9\n" <>
    "andBool #rangeAddress( " <> show Caller <> ")\n" <> 
    "andBool #rangeAddress( " <> show Origin <> ")\n" <>
    "andBool #rangeUInt(256, " <> show  Timestamp <> ")\n" <>
    -- "andBool #rangeUInt(256, ECREC_BAL)" <>
    -- "andBool #rangeUInt(256, SHA256_BAL)" <>
    -- "andBool #rangeUInt(256, RIP160_BAL)" <>
    -- "andBool #rangeUInt(256, ID_BAL)" <>
    -- "andBool #rangeUInt(256, MODEXP_BAL)" <>
    -- "andBool #rangeUInt(256, ECADD_BAL)" <>
    -- "andBool #rangeUInt(256, ECMUL_BAL)" <>
    -- "andBool #rangeUInt(256, ECPAIRING_BAL)" <>
    "andBool " <> show Calldepth <> " <=Int 1024\n" <>
    "andBool #rangeUInt(256, " <> show Callvalue <> ")\n" <>
    "andBool #rangeUInt(256, " <> show Chainid <>  " )\n"



mkTerm :: SolcContract -> Map Id SolcContract -> Behaviour -> (String, String)
mkTerm this accounts behaviour@Behaviour{..} = (name, term)
  where code = if _creation then _creationCode this
               else _runtimeCode this
        pass = _mode == Pass
        repl '_' = '.'
        repl  c  = c
        name = _contract <> "_" <> _name <> "_" <> show _mode
        term =  "rule [" <> (fmap repl name) <> "]:\n"
             <> "k" |- "#execute => #halt"
             <> "exit-code" |- "1"
             <> "mode" |- "NORMAL"
             <> "schedule" |- "ISTANBUL"
             <> "evm" |- ("\n"
                  <> "output" |- if pass then kAbiEncode _returns else ".ByteArray"
                  <> "statusCode" |- kStatus _mode
                  <> "callStack" |- "CallStack"
                  <> "interimStates" |- "_"
                  <> "touchedAccounts" |- "_"
                  <> "callState" |- ("\n"
                     <> "program" |- kByteStack code
                     <> "jumpDests" |- ("#computeValidJumpDests(" <> kByteStack code <> ")")
                     <> "id" |- kVar _contract
                     <> "caller" |- (show Caller)
                     <> "callData" |- kCalldata _interface
                     <> "callValue" |- (show Callvalue)
                        -- the following are set to the values they have
                        -- at the beginning of a CALL. They can take a
                        -- more general value in "internal" specs.
                     <> "wordStack" |- ".WordStack => _"
                     <> "localMem"  |- ".Map => _"
                     <> "pc" |- "0 => _"
                     <> "gas" |- "300000 => _" -- can be generalized in the future
                     <> "memoryUsed" |- "0 => _"
                     <> "callGas" |- "_ => _"
                     <> "static" |- "false" -- TODO: generalize
                     <> "callDepth" |- (show Calldepth)
                     )
                  <> "substate" |- ("\n"
                      <> "selfDestruct" |- "_ => _"
                      <> "log" |- "_ => _" --TODO: spec logs?
                      <> "refund" |- "_ => _"
                      )
                  <> "gasPrice" |- "_" --could be environment var
                  <> "origin" |- show Origin
                  <> "blockhashes" |- "_"
                  <> "block" |- ("\n"
                     <> "previousHash" |- "_"
                     <> "ommersHash" |- "_"
                     <> "coinbase" |- (show Coinbase)
                     <> "stateRoot" |- "_"
                     <> "transactionsRoot" |- "_"
                     <> "receiptsRoot" |- "_"
                     <> "logsBloom" |- "_"
                     <> "difficulty" |- (show Difficulty)
                     <> "number" |- (show Blocknumber)
                     <> "gasLimit" |- "_"
                     <> "gasUsed" |- "_"
                     <> "timestamp" |- (show Timestamp)
                     <> "extraData" |- "_"
                     <> "mixHash" |- "_"
                     <> "blockNonce" |- "_"
                     <> "ommerBlockHeaders" |- "_"
                     )
                )
                <> "network" |- ("\n"
                  <> "activeAccounts" |- "_"
                  <> "accounts" |- ("\n" <> unpack (Text.intercalate "\n" (fmap (\a -> pack $ kAccount pass a (fromJust $ Map.lookup a accounts) (fromJust $ Map.lookup a _stateUpdates)) _contracts)))
                  <> "txOrder" |- "_"
                  <> "txPending" |- "_"
                  <> "messages" |- "_"
                  )
               <> "\nrequires "
               <> defaultConditions (kVar _contract) <> "\n andBool\n"
               <> kExprBool _preconditions
