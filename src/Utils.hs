{-# LANGUAGE
OverloadedStrings,
TemplateHaskell,
GeneralizedNewtypeDeriving,
DeriveDataTypeable,
NumDecimals,
NoImplicitPrelude
  #-}


module Utils
(
  -- * Text
  format,
  tshow,

  -- * Lists
  moveUp,
  moveDown,
  deleteFirst,

  -- * URLs
  Url,
  sanitiseUrl,

  -- * UID
  Uid(..),
  randomUid,
  uid_,

  -- * Lucid
  includeJS,
  includeCSS,

  -- * Spock
  lucid,
)
where


-- General
import BasePrelude
-- Monads and monad transformers
import Control.Monad.IO.Class
-- Random
import System.Random
-- Text
import qualified Data.Text as T
import Data.Text (Text)
import qualified Data.Text.Lazy as TL
-- Formatting
import           Data.Text.Format hiding (format)
import qualified Data.Text.Format        as Format
import qualified Data.Text.Format.Params as Format
import qualified Data.Text.Buildable     as Format
-- Web
import Lucid
import Web.Spock
import Text.HTML.SanitizeXSS (sanitaryURI)
import Web.PathPieces
-- acid-state
import Data.SafeCopy


-- | Format a string (a bit like 'Text.Printf.printf' but with different
-- syntax). The version in "Data.Text.Format" returns lazy text, but we
-- use strict text everywhere.
format :: Format.Params ps => Format -> ps -> Text
format f ps = TL.toStrict (Format.format f ps)

tshow :: Show a => a -> Text
tshow = T.pack . show

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

type Url = Text

sanitiseUrl :: Url -> Maybe Url
sanitiseUrl u
  | not (sanitaryURI u)       = Nothing
  | "http:" `T.isPrefixOf` u  = Just u
  | "https:" `T.isPrefixOf` u = Just u
  | otherwise                 = Just ("http://" <> u)

-- | Unique id, used for many things – categories, items, and anchor ids.
-- Note that in HTML 5 using numeric ids for divs, spans, etc is okay.
newtype Uid = Uid {uidToText :: Text}
  deriving (Eq, PathPiece, Format.Buildable, Data)

deriveSafeCopy 0 'base ''Uid

instance IsString Uid where
  fromString = Uid . T.pack

randomUid :: MonadIO m => m Uid
randomUid = liftIO $ Uid . tshow <$> randomRIO (10e8 :: Int, 10e9-1)

uid_ :: Uid -> Attribute
uid_ = id_ . uidToText

includeJS :: Monad m => Url -> HtmlT m ()
includeJS url = with (script_ "") [src_ url]

includeCSS :: Monad m => Url -> HtmlT m ()
includeCSS url = link_ [rel_ "stylesheet", type_ "text/css", href_ url]

lucid :: MonadIO m => HtmlT IO a -> ActionCtxT ctx m a
lucid h = do
  htmlText <- liftIO (renderTextT h)
  html (TL.toStrict htmlText)
