{-# LANGUAGE
OverloadedStrings,
GeneralizedNewtypeDeriving,
FlexibleContexts,
FlexibleInstances,
TypeFamilies,
NoImplicitPrelude
  #-}


{-# OPTIONS_GHC -fno-warn-orphans #-}


module Utils
(
  -- * Lists
  moveUp,
  moveDown,
  deleteFirst,
  insertAtGuaranteed,
  ordNub,

  -- * 'Eq'
  equating,

  -- * URLs
  Url,
  sanitiseUrl,
  makeSlug,

  -- * IP
  sockAddrToIP,
  
  -- * UID
  Uid(..),
  Node,
  randomShortUid,
  randomLongUid,
  uid_,

  -- * Lucid
  includeJS,
  includeCSS,

  -- * Spock
  atomFeed,

  -- * Safecopy
  GenConstructor(..),
  genVer,
  MigrateConstructor(..),
  migrateVer,

  -- * Instances
  -- ** 'MonadThrow' for 'HtmlT'
)
where


import BasePrelude
-- Lenses
import Lens.Micro.Platform hiding ((&))
-- Monads and monad transformers
import Control.Monad.Trans
import Control.Monad.Catch
-- Containers
import qualified Data.Set as S
-- Hashable (needed for Uid)
import Data.Hashable
-- Randomness
import System.Random
-- Text
import Data.Text.All (Text)
import qualified Data.Text.All as T
-- JSON
import qualified Data.Aeson as A
-- Network
import qualified Network.Socket as Network
import Data.IP
-- Web
import Lucid
import Web.Spock
import Text.HTML.SanitizeXSS (sanitaryURI)
import Web.PathPieces
-- Feeds
import qualified Text.Atom.Feed        as Atom
import qualified Text.Atom.Feed.Export as Atom
import qualified Text.XML.Light.Output as XML
-- acid-state
import Data.SafeCopy
-- Template Haskell
import Language.Haskell.TH


-- | Move the -1st element that satisfies the predicate- up.
moveUp :: (a -> Bool) -> [a] -> [a]
moveUp p (x:y:xs) = if p y then (y:x:xs) else x : moveUp p (y:xs)
moveUp _ xs = xs

-- | Move the -1st element that satisfies the predicate- down.
moveDown :: (a -> Bool) -> [a] -> [a]
moveDown p (x:y:xs) = if p x then (y:x:xs) else x : moveDown p (y:xs)
moveDown _ xs = xs

deleteFirst :: (a -> Bool) -> [a] -> [a]
deleteFirst _   []   = []
deleteFirst f (x:xs) = if f x then xs else x : deleteFirst f xs

insertAtGuaranteed :: Int -> a -> [a] -> [a]
insertAtGuaranteed _ a   []   = [a]
insertAtGuaranteed 0 a   xs   = a:xs
insertAtGuaranteed n a (x:xs) = x : insertAtGuaranteed (n-1) a xs

ordNub :: Ord a => [a] -> [a]
ordNub = go mempty
  where
    go _ [] = []
    go s (x:xs) | x `S.member` s = go s xs
                | otherwise      = x : go (S.insert x s) xs

equating :: Eq b => (a -> b) -> (a -> a -> Bool)
equating f = (==) `on` f

type Url = Text

sanitiseUrl :: Url -> Maybe Url
sanitiseUrl u
  | not (sanitaryURI u)       = Nothing
  | "http:" `T.isPrefixOf` u  = Just u
  | "https:" `T.isPrefixOf` u = Just u
  | otherwise                 = Just ("http://" <> u)

-- | Make text suitable for inclusion into an URL (by turning spaces into
-- hyphens and so on)
makeSlug :: Text -> Text
makeSlug =
  T.intercalate "-" . T.words .
  T.filter (\c -> isLetter c || isDigit c || c == ' ' || c == '-') .
  T.toLower .
  T.map (\x -> if x == '_' || x == '/' then '-' else x)

deriveSafeCopySimple 0 'base ''IPv4
deriveSafeCopySimple 0 'base ''IPv6
deriveSafeCopySimple 0 'base ''IP

sockAddrToIP :: Network.SockAddr -> Maybe IP
sockAddrToIP (Network.SockAddrInet  _   x)   = Just (IPv4 (fromHostAddress x))
sockAddrToIP (Network.SockAddrInet6 _ _ x _) = Just (IPv6 (fromHostAddress6 x))
sockAddrToIP _ = Nothing

-- | Unique id, used for many things – categories, items, and anchor ids.
newtype Uid a = Uid {uidToText :: Text}
  deriving (Eq, Ord, Show, PathPiece, T.Buildable, Hashable, A.ToJSON)

-- See Note [acid-state]
deriveSafeCopySimple 2 'extension ''Uid

newtype Uid_v1 a = Uid_v1 {uidToText_v1 :: Text}

-- TODO: at the next migration change this to deriveSafeCopySimple!
deriveSafeCopy 1 'base ''Uid_v1

instance SafeCopy a => Migrate (Uid a) where
  type MigrateFrom (Uid a) = Uid_v1 a
  migrate Uid_v1{..} = Uid {
    uidToText = uidToText_v1 }

instance IsString (Uid a) where
  fromString = Uid . T.pack

randomText :: MonadIO m => Int -> m Text
randomText n = liftIO $ do
  -- We don't want the 1st char to be a digit. Just in case (I don't really
  -- have a good reason). Maybe to prevent Javascript from doing automatic
  -- conversions or something (tho it should never happen).
  x <- randomRIO ('a', 'z')
  let randomChar = do
        i <- randomRIO (0, 35)
        return $ if i < 10 then toEnum (fromEnum '0' + i)
                           else toEnum (fromEnum 'a' + i - 10)
  xs <- replicateM (n-1) randomChar
  return (T.pack (x:xs))

randomLongUid :: MonadIO m => m (Uid a)
randomLongUid = Uid <$> randomText 12

-- These are only used for items and categories (because their uids can occur
-- in links and so they should look a bit nicer).
randomShortUid :: MonadIO m => m (Uid a)
randomShortUid = Uid <$> randomText 8

-- | A marker for Uids that would be used with HTML nodes
data Node

uid_ :: Uid Node -> Attribute
uid_ = id_ . uidToText

includeJS :: Monad m => Url -> HtmlT m ()
includeJS url = with (script_ "") [src_ url]

includeCSS :: Monad m => Url -> HtmlT m ()
includeCSS url = link_ [rel_ "stylesheet", type_ "text/css", href_ url]

atomFeed :: MonadIO m => Atom.Feed -> ActionCtxT ctx m ()
atomFeed feed = do
  setHeader "Content-Type" "application/atom+xml; charset=utf-8"
  bytes $ T.encodeUtf8 (T.pack (XML.ppElement (Atom.xmlFeed feed)))

data GenConstructor = Copy Name | Custom String [(String, Name)]

genVer :: Name -> Int -> [GenConstructor] -> Q [Dec]
genVer tyName ver constructors = do
  -- Get information about the new version of the datatype
  TyConI (DataD _cxt _name _vars cons _deriving) <- reify tyName
  -- Let's do some checks first
  unless (null _cxt) $
    fail "genVer: can't yet work with types with context"
  unless (null _vars) $
    fail "genVer: can't yet work with types with variables"

  let oldName n = mkName (nameBase n ++ "_v" ++ show ver)

  let copyConstructor conName =
        case [c | c@(RecC n _) <- cons, n == conName] of
          [] -> fail ("genVer: couldn't find a record constructor " ++
                      show conName)
          [RecC _ fields] ->
            recC (oldName conName)
                 (map return (fields & each._1 %~ oldName))
          other -> fail ("genVer: copyConstructor: got " ++ show other)

  let customConstructor conName fields =
        recC (oldName (mkName conName))
             [varStrictType (oldName (mkName fName))
                            (strictType notStrict (conT fType))
               | (fName, fType) <- fields]

  cons' <- for constructors $ \genCons -> do
    case genCons of
      Copy conName -> copyConstructor conName
      Custom conName fields -> customConstructor conName fields

  decl <- dataD
    -- no context
    (cxt [])
    -- name of our type (e.g. SomeType_v3 if the previous version was 3)
    (oldName tyName)
    -- no variables
    []
    -- constructors
    (map return cons')
    -- not deriving anything
    []
  return [decl]

data MigrateConstructor = CopyM Name | CustomM Name ExpQ

migrateVer :: Name -> Int -> [MigrateConstructor] -> Q Exp
migrateVer tyName ver constructors = do
  -- Get information about the new version of the datatype
  TyConI (DataD _cxt _name _vars cons _deriving) <- reify tyName
  -- Let's do some checks first
  unless (null _cxt) $
    fail "migrateVer: can't yet work with types with context"
  unless (null _vars) $
    fail "migrateVer: can't yet work with types with variables"

  let oldName n = mkName (nameBase n ++ "_v" ++ show ver)

  arg <- newName "x"

  let copyConstructor conName =
        case [c | c@(RecC n _) <- cons, n == conName] of
          [] -> fail ("migrateVer: couldn't find a record constructor " ++
                      show conName)
          [RecC _ fields] -> do
            -- SomeConstr_v3{} -> SomeConstr (field1 x) (field2 x) ...
            let getField f = varE (oldName (f ^. _1)) `appE` varE arg
            match (recP (oldName conName) [])
                  (normalB (appsE (conE conName : map getField fields)))
                  []
          other -> fail ("migrateVer: copyConstructor: got " ++ show other)

  let customConstructor conName res =
        match (recP (oldName conName) [])
              (normalB res)
              []

  branches' <- for constructors $ \genCons -> do
    case genCons of
      CopyM conName -> copyConstructor conName
      CustomM conName res -> customConstructor conName res

  lam1E (varP arg) (caseE (varE arg) (map return branches'))

instance MonadThrow m => MonadThrow (HtmlT m) where
  throwM e = lift $ throwM e
