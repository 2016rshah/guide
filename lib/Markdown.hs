{-# LANGUAGE
OverloadedStrings,
FlexibleInstances,
FlexibleContexts,
NoImplicitPrelude
  #-}


module Markdown
(
  -- * Types
  MarkdownInline(..),
  MarkdownBlock(..),
  MarkdownBlockWithTOC(..),

  -- * Lenses
  mdHtml,
  mdText,
  mdMarkdown,
  mdIdPrefix,
  mdTree,
  mdTOC,

  -- * Converting text to Markdown
  toMarkdownInline,
  toMarkdownBlock,
  toMarkdownBlockWithTOC,

  -- * Misc
  renderMD,
  markdownNull,
)
where


import BasePrelude hiding (Space)
-- Lenses
import Lens.Micro.Platform hiding ((&))
-- Monad transformers and monads
import Control.Monad.State
-- Text
import qualified Data.Text.All as T
import Data.Text.All (Text)
-- ByteString
import qualified Data.ByteString.Lazy as BSL
import qualified Data.ByteString as BS
import Data.ByteString (ByteString)
-- Parsing
import Text.Megaparsec hiding (State)
import Text.Megaparsec.Text
-- JSON
import qualified Data.Aeson as A
-- HTML
import Lucid
import Text.HTML.SanitizeXSS
-- Containers
import Data.Tree
import qualified Data.Set as S
import Data.Set (Set)
-- Markdown
import CMark hiding (Node)
import qualified CMark as MD
import CMark.Highlight
import CMark.Sections
import ShortcutLinks
import ShortcutLinks.All (hackage)
-- acid-state
import Data.SafeCopy

-- Local
import Utils


data MarkdownInline = MarkdownInline {
  markdownInlineMdText     :: Text,
  markdownInlineMdHtml     :: ByteString,
  markdownInlineMdMarkdown :: ![MD.Node] }

data MarkdownBlock = MarkdownBlock {
  markdownBlockMdText     :: Text,
  markdownBlockMdHtml     :: ByteString,
  markdownBlockMdMarkdown :: ![MD.Node] }

data MarkdownBlockWithTOC = MarkdownBlockWithTOC {
  markdownBlockWithTOCMdText     :: Text,
  markdownBlockWithTOCMdTree     :: !(Document Text ByteString),
  markdownBlockWithTOCMdIdPrefix :: Text,
  markdownBlockWithTOCMdTOC      :: Forest ([MD.Node], Text) }

makeFields ''MarkdownInline
makeFields ''MarkdownBlock
makeFields ''MarkdownBlockWithTOC

parseMD :: Text -> [MD.Node]
parseMD s =
  let MD.Node _ DOCUMENT ns =
        highlightNode . shortcutLinks . commonmarkToNode [optSafe] $ s
  in  ns

renderMD :: [MD.Node] -> ByteString
renderMD ns
  -- See https://github.com/jgm/cmark/issues/147
  | any isInlineNode ns =
      T.encodeUtf8 . sanitize . T.concat . map (nodeToHtml []) $ ns
  | otherwise =
      T.encodeUtf8 . sanitize . nodeToHtml [] $ MD.Node Nothing DOCUMENT ns

isInlineNode :: MD.Node -> Bool
isInlineNode (MD.Node _ tp _) = case tp of
  EMPH              -> True
  STRONG            -> True
  LINK _ _          -> True
  CUSTOM_INLINE _ _ -> True
  SOFTBREAK         -> True
  LINEBREAK         -> True
  TEXT _            -> True
  CODE _            -> True
  HTML_INLINE _     -> True
  _other            -> False

-- | Convert a Markdown structure to a string with formatting removed.
stringify :: [MD.Node] -> Text
stringify = T.concat . map go
  where
    go (MD.Node _ tp ns) = case tp of
      DOCUMENT          -> stringify ns
      THEMATIC_BREAK    -> stringify ns
      PARAGRAPH         -> stringify ns
      BLOCK_QUOTE       -> stringify ns
      CUSTOM_BLOCK _ _  -> stringify ns
      HEADING _         -> stringify ns
      LIST _            -> stringify ns
      ITEM              -> stringify ns
      EMPH              -> stringify ns
      STRONG            -> stringify ns
      LINK _ _          -> stringify ns
      IMAGE _ _         -> stringify ns
      CUSTOM_INLINE _ _ -> stringify ns
      CODE         xs   -> xs
      CODE_BLOCK _ xs   -> xs
      TEXT         xs   -> xs
      SOFTBREAK         -> " "
      LINEBREAK         -> " "
      HTML_BLOCK _      -> ""
      HTML_INLINE _     -> ""

-- | Flatten Markdown by concatenating all block elements.
extractInlines :: [MD.Node] -> [MD.Node]
extractInlines = concatMap go
  where
    go node@(MD.Node _ tp ns) = case tp of
      -- Block containers
      DOCUMENT          -> extractInlines ns
      BLOCK_QUOTE       -> extractInlines ns
      CUSTOM_BLOCK _ _  -> extractInlines ns
      LIST _            -> extractInlines ns
      ITEM              -> extractInlines ns
      -- Inline containers
      PARAGRAPH         -> ns
      HEADING _         -> ns
      IMAGE _ _         -> ns
      -- Inlines
      EMPH              -> [node]
      STRONG            -> [node]
      LINK _ _          -> [node]
      CUSTOM_INLINE _ _ -> [node]
      SOFTBREAK         -> [node]
      LINEBREAK         -> [node]
      TEXT _            -> [node]
      CODE _            -> [node]
      -- Other stuff
      THEMATIC_BREAK    -> []
      HTML_BLOCK xs     -> [MD.Node Nothing (CODE xs) []]
      HTML_INLINE xs    -> [MD.Node Nothing (CODE xs) []]
      CODE_BLOCK _ xs   -> [MD.Node Nothing (CODE xs) []]

shortcutLinks :: MD.Node -> MD.Node
shortcutLinks node@(MD.Node pos (LINK url title) ns) | '@' <- T.head url =
  -- %20s are possibly introduced by cmark (Pandoc definitely adds them,
  -- no idea about cmark but better safe than sorry) and so they need to
  -- be converted back to spaces
  case parseLink (T.replace "%20" " " url) of
    Left _err -> MD.Node pos (LINK url title) (map shortcutLinks ns)
    Right (shortcut, opt, text) -> do
      let text' = fromMaybe (stringify [node]) text
      let shortcuts = (["hk"], hackage) : allShortcuts
      case useShortcutFrom shortcuts shortcut opt text' of
        Success link ->
          MD.Node pos (LINK link title) (map shortcutLinks ns)
        Warning warnings link ->
          let warningText = "[warnings when processing shortcut link: " <>
                            T.pack (intercalate ", " warnings) <> "]"
              warningNode = MD.Node Nothing (TEXT warningText) []
          in  MD.Node pos (LINK link title)
                             (warningNode : map shortcutLinks ns)
        Failure err ->
          let errorText = "[error when processing shortcut link: " <>
                          T.pack err <> "]"
          in  MD.Node Nothing (TEXT errorText) []
shortcutLinks (MD.Node pos tp ns) =
  MD.Node pos tp (map shortcutLinks ns)

-- TODO: this should be in the shortcut-links package itself

-- | Parse a shortcut link. Allowed formats:
--
-- @
-- \@name
-- \@name:text
-- \@name(option)
-- \@name(option):text
-- @
parseLink :: Text -> Either String (Text, Maybe Text, Maybe Text)
parseLink = either (Left . show) Right . parse p ""
  where
    shortcut = some (alphaNumChar <|> char '-')
    opt      = char '(' *> some (noneOf [')']) <* char ')'
    text     = char ':' *> some anyChar
    p :: Parser (Text, Maybe Text, Maybe Text)
    p = do
      char '@'
      (,,) <$> T.pack <$> shortcut
           <*> optional (T.pack <$> opt)
           <*> optional (T.pack <$> text)

toMarkdownInline :: Text -> MarkdownInline
toMarkdownInline s = MarkdownInline {
  markdownInlineMdText     = s,
  markdownInlineMdHtml     = html,
  markdownInlineMdMarkdown = inlines }
  where
    inlines = extractInlines (parseMD s)
    html = renderMD inlines

toMarkdownBlock :: Text -> MarkdownBlock
toMarkdownBlock s = MarkdownBlock {
  markdownBlockMdText     = s,
  markdownBlockMdHtml     = html,
  markdownBlockMdMarkdown = doc }
  where
    doc = parseMD s
    html = renderMD doc

toMarkdownBlockWithTOC :: Text -> Text -> MarkdownBlockWithTOC
toMarkdownBlockWithTOC idPrefix s = MarkdownBlockWithTOC {
  markdownBlockWithTOCMdText     = s,
  markdownBlockWithTOCMdIdPrefix = idPrefix,
  markdownBlockWithTOCMdTree     = tree,
  markdownBlockWithTOCMdTOC      = toc }
  where
    blocks :: [MD.Node]
    blocks = parseMD s
    --
    slugify :: Text -> Text
    slugify x = idPrefix <> makeSlug x
    --
    tree :: Document Text ByteString
    tree = renderContents . slugifyDocument slugify $
             nodesToDocument (Ann s blocks)
    --
    toc :: Forest ([MD.Node], Text)  -- (heading, slug)
    toc = sections tree
            & each.each %~ (\Section{..} -> (annValue heading, headingAnn))

renderContents :: Document a b -> Document a ByteString
renderContents doc = doc {
  prefaceAnn = renderMD (annValue (preface doc)),
  sections = over (each.each) renderSection (sections doc) }
  where
    renderSection sec = sec {
      contentAnn = renderMD (annValue (content sec)) }

slugifyDocument :: (Text -> Text) -> Document a b -> Document Text b
slugifyDocument slugify doc = doc {
  sections = evalState ((each.each) process (sections doc)) mempty }
  where
    process :: Section a b -> State (Set Text) (Section Text b)
    process sec = do
      previousIds <- get
      let slug = until (`S.notMember` previousIds) (<> "_")
                   (slugify (stringify (annValue (heading sec))))
      modify (S.insert slug)
      return sec{headingAnn = slug}

instance Show MarkdownInline where
  show = show . view mdText
instance Show MarkdownBlock where
  show = show . view mdText
instance Show MarkdownBlockWithTOC where
  show = show . view mdText

instance A.ToJSON MarkdownInline where
  toJSON md = A.object [
    "text" A..= (md^.mdText),
    "html" A..= T.decodeUtf8 (md^.mdHtml) ]
instance A.ToJSON MarkdownBlock where
  toJSON md = A.object [
    "text" A..= (md^.mdText),
    "html" A..= T.decodeUtf8 (md^.mdHtml) ]
instance A.ToJSON MarkdownBlockWithTOC where
  toJSON md = A.object [
    "text" A..= (md^.mdText) ]

instance ToHtml MarkdownInline where
  toHtmlRaw = toHtml
  toHtml    = toHtmlRaw . view mdHtml
instance ToHtml MarkdownBlock where
  toHtmlRaw = toHtml
  toHtml    = toHtmlRaw . view mdHtml
instance ToHtml MarkdownBlockWithTOC where
  toHtmlRaw = toHtml
  toHtml    = toHtmlRaw . renderDoc . view mdTree
    where
      renderDoc Document{..} = BS.concat $
        prefaceAnn :
        map renderSection (concatMap flatten sections)
      renderSection Section{..} = BSL.toStrict . renderBS $ do
        mkH $ do
          span_ [id_ headingAnn] ""
          toHtmlRaw (renderMD (annValue heading))
        toHtmlRaw contentAnn
        where
          mkH = case level of
            1 -> h1_; 2 -> h2_; 3 -> h3_;
            4 -> h4_; 5 -> h5_; 6 -> h6_;
            _other -> error "Markdown.toHtml: level > 6"

instance SafeCopy MarkdownInline where
  version = 0
  kind = base
  putCopy = contain . safePut . view mdText
  getCopy = contain $ toMarkdownInline <$> safeGet
instance SafeCopy MarkdownBlock where
  version = 0
  kind = base
  putCopy = contain . safePut . view mdText
  getCopy = contain $ toMarkdownBlock <$> safeGet
instance SafeCopy MarkdownBlockWithTOC where
  version = 0
  kind = base
  putCopy md = contain $ do
    safePut (md ^. mdIdPrefix)
    safePut (md ^. mdText)
  getCopy = contain $
    toMarkdownBlockWithTOC <$> safeGet <*> safeGet

-- | Is a piece of Markdown empty?
markdownNull :: HasMdText a Text => a -> Bool
markdownNull = T.null . view mdText
