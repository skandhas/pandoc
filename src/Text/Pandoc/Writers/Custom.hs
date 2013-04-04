{-# LANGUAGE OverlappingInstances, FlexibleInstances, OverloadedStrings #-}
{-
Copyright (C) 2012 John MacFarlane <jgm@berkeley.edu>

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
-}

{- |
   Module      : Text.Pandoc.Writers.Custom
   Copyright   : Copyright (C) 2012 John MacFarlane
   License     : GNU GPL, version 2 or above

   Maintainer  : John MacFarlane <jgm@berkeley.edu>
   Stability   : alpha
   Portability : portable

Conversion of 'Pandoc' documents to custom markup using
a lua writer.
-}
module Text.Pandoc.Writers.Custom ( writeCustom ) where
import Text.Pandoc.Definition
import Text.Pandoc.Options
import Text.Pandoc.Shared
import Data.List ( intersperse )
import Scripting.Lua (LuaState, StackValue, callfunc)
import qualified Scripting.Lua as Lua
import Text.Pandoc.UTF8 (fromString, toString)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as C8
import Data.Monoid

attrToAssocList :: Attr -> [(ByteString, ByteString)]
attrToAssocList (id',classes,keyvals) =
      ("id", fromString id')
    : ("class", fromString $ unwords classes)
    : map (\(x,y) -> (fromString x, fromString y)) keyvals

getList :: StackValue a => LuaState -> Int -> IO [a]
getList lua i' = do
  continue <- Lua.next lua i'
  if continue
     then do
       next <- Lua.peek lua (-1)
       Lua.pop lua 1
       x <- maybe (fail "peek returned Nothing") return next
       rest <- getList lua i'
       return (x : rest)
     else return []

instance StackValue ByteString where
    push l x = Lua.push l $ C8.unpack x
    peek l n = (fmap . fmap) C8.pack (Lua.peek l n)
    valuetype _ = Lua.TSTRING

addValue :: StackValue a => LuaState -> (Int, a) -> IO ()
addValue lua (i, x) = Lua.push lua x >> Lua.rawseti lua (-2) i

instance StackValue a => StackValue [a] where
  push lua xs = do
    Lua.createtable lua (length xs + 1) 0
    mapM_ (addValue lua) $ zip [1..] xs
  peek lua i = do
    top <- Lua.gettop lua
    let i' = if i < 0 then top + i + 1 else i
    Lua.pushnil lua
    lst <- getList lua i'
    Lua.pop lua 1
    return (Just lst)
  valuetype _ = Lua.TTABLE

instance (StackValue a, StackValue b) => StackValue [(a,b)] where
  push lua xs = do
    Lua.createtable lua (length xs + 1) 0
    let addValue (k, v) = Lua.push lua k >> Lua.push lua v >>
                          Lua.rawset lua (-3)
    mapM_ addValue xs
  peek lua i = undefined -- not needed for our purposes
  valuetype _ = Lua.TTABLE

instance StackValue [Inline] where
  push l ils = Lua.push l . C8.unpack =<< inlineListToCustom l ils
  peek l n = undefined
  valuetype _ = Lua.TSTRING

-- | Convert Pandoc to custom markup.
writeCustom :: FilePath -> WriterOptions -> Pandoc -> IO String
writeCustom luaFile opts (Pandoc _ blocks) = do
  luaScript <- readFile luaFile
  lua <- Lua.newstate
  Lua.openlibs lua
  Lua.loadstring lua luaScript "custom"
  Lua.call lua 0 0
  -- TODO - call hierarchicalize, so we have that info
  body <- blockListToCustom lua blocks
  Lua.close lua
  return $ toString body

-- | Convert Pandoc block element to Custom.
blockToCustom :: LuaState      -- ^ Lua state
              -> Block         -- ^ Block element
              -> IO ByteString

blockToCustom _ Null = return ""

blockToCustom lua (Plain inlines) = inlineListToCustom lua inlines

blockToCustom lua (Para [Image txt (src,tit)]) =
  callfunc lua "CaptionedImage" lua src tit txt

blockToCustom lua (Para inlines) = callfunc lua "Para" inlines

blockToCustom lua (RawBlock format str) =
  callfunc lua "RawBlock" format (fromString str)

blockToCustom lua HorizontalRule = callfunc lua "HorizontalRule"

blockToCustom lua (Header level attr inlines) =
  callfunc lua "Header" level (attrToAssocList attr) inlines

blockToCustom lua (CodeBlock attr str) =
  callfunc lua "CodeBlock" (attrToAssocList attr) (fromString str)

{-

lockToCustom opts (BlockQuote blocks) = do
  contents <- blockListToCustom opts blocks
  return $ "<blockquote>" ++ contents ++ "</blockquote>" 

blockToCustom opts (Table capt aligns widths headers rows') = do
  let alignStrings = map alignmentToString aligns
  captionDoc <- if null capt
                   then return ""
                   else do
                      c <- inlineListToCustom opts capt
                      return $ "<caption>" ++ c ++ "</caption>\n"
  let percent w = show (truncate (100*w) :: Integer) ++ "%"
  let coltags = if all (== 0.0) widths
                   then ""
                   else unlines $ map
                         (\w -> "<col width=\"" ++ percent w ++ "\" />") widths
  head' <- if all null headers
              then return ""
              else do
                 hs <- tableRowToCustom opts alignStrings 0 headers
                 return $ "<thead>\n" ++ hs ++ "\n</thead>\n"
  body' <- zipWithM (tableRowToCustom opts alignStrings) [1..] rows'
  return $ "<table>\n" ++ captionDoc ++ coltags ++ head' ++
            "<tbody>\n" ++ unlines body' ++ "</tbody>\n</table>\n"

blockToCustom opts x@(BulletList items) = do
  oldUseTags <- get >>= return . stUseTags
  let useTags = oldUseTags || not (isSimpleList x)
  if useTags
     then do
        modify $ \s -> s { stUseTags = True }
        contents <- mapM (listItemToCustom opts) items
        modify $ \s -> s { stUseTags = oldUseTags }
        return $ "<ul>\n" ++ vcat contents ++ "</ul>\n"
     else do
        modify $ \s -> s { stListLevel = stListLevel s ++ "*" }
        contents <- mapM (listItemToCustom opts) items
        modify $ \s -> s { stListLevel = init (stListLevel s) }
        return $ vcat contents ++ "\n"

blockToCustom opts x@(OrderedList attribs items) = do
  oldUseTags <- get >>= return . stUseTags
  let useTags = oldUseTags || not (isSimpleList x)
  if useTags
     then do
        modify $ \s -> s { stUseTags = True }
        contents <- mapM (listItemToCustom opts) items
        modify $ \s -> s { stUseTags = oldUseTags }
        return $ "<ol" ++ listAttribsToString attribs ++ ">\n" ++ vcat contents ++ "</ol>\n"
     else do
        modify $ \s -> s { stListLevel = stListLevel s ++ "#" }
        contents <- mapM (listItemToCustom opts) items
        modify $ \s -> s { stListLevel = init (stListLevel s) }
        return $ vcat contents ++ "\n"

blockToCustom opts x@(DefinitionList items) = do
  oldUseTags <- get >>= return . stUseTags
  let useTags = oldUseTags || not (isSimpleList x)
  if useTags
     then do
        modify $ \s -> s { stUseTags = True }
        contents <- mapM (definitionListItemToCustom opts) items
        modify $ \s -> s { stUseTags = oldUseTags }
        return $ "<dl>\n" ++ vcat contents ++ "</dl>\n"
     else do
        modify $ \s -> s { stListLevel = stListLevel s ++ ";" }
        contents <- mapM (definitionListItemToCustom opts) items
        modify $ \s -> s { stListLevel = init (stListLevel s) }
        return $ vcat contents ++ "\n"

-- Auxiliary functions for lists:

-- | Convert ordered list attributes to HTML attribute string
listAttribsToString :: ListAttributes -> String
listAttribsToString (startnum, numstyle, _) =
  let numstyle' = camelCaseToHyphenated $ show numstyle
  in  (if startnum /= 1
          then " start=\"" ++ show startnum ++ "\""
          else "") ++
      (if numstyle /= DefaultStyle
          then " style=\"list-style-type: " ++ numstyle' ++ ";\""
          else "")

-- | Convert bullet or ordered list item (list of blocks) to Custom.
listItemToCustom :: LuaState -> [Block] -> State WriterState String
listItemToCustom opts items = do
  contents <- blockListToCustom opts items
  useTags <- get >>= return . stUseTags
  if useTags
     then return $ "<li>" ++ contents ++ "</li>"
     else do
       marker <- get >>= return . stListLevel
       return $ marker ++ " " ++ contents

-- | Convert definition list item (label, list of blocks) to Custom.
definitionListItemToCustom :: LuaState
                             -> ([Inline],[[Block]]) 
                             -> State WriterState String
definitionListItemToCustom opts (label, items) = do
  labelText <- inlineListToCustom opts label
  contents <- mapM (blockListToCustom opts) items
  useTags <- get >>= return . stUseTags
  if useTags
     then return $ "<dt>" ++ labelText ++ "</dt>\n" ++
           (intercalate "\n" $ map (\d -> "<dd>" ++ d ++ "</dd>") contents)
     else do
       marker <- get >>= return . stListLevel
       return $ marker ++ " " ++ labelText ++ "\n" ++
           (intercalate "\n" $ map (\d -> init marker ++ ": " ++ d) contents)

-- Auxiliary functions for tables:

tableRowToCustom :: LuaState
                    -> [String]
                    -> Int
                    -> [[Block]]
                    -> State WriterState String
tableRowToCustom opts alignStrings rownum cols' = do
  let celltype = if rownum == 0 then "th" else "td"
  let rowclass = case rownum of
                      0                  -> "header"
                      x | x `rem` 2 == 1 -> "odd"
                      _                  -> "even"
  cols'' <- sequence $ zipWith 
            (\alignment item -> tableItemToCustom opts celltype alignment item) 
            alignStrings cols'
  return $ "<tr class=\"" ++ rowclass ++ "\">\n" ++ unlines cols'' ++ "</tr>"

alignmentToString :: Alignment -> [Char]
alignmentToString alignment = case alignment of
                                 AlignLeft    -> "left"
                                 AlignRight   -> "right"
                                 AlignCenter  -> "center"
                                 AlignDefault -> "left"

tableItemToCustom :: LuaState
                     -> String
                     -> String
                     -> [Block]
                     -> State WriterState String
tableItemToCustom opts celltype align' item = do
  let mkcell x = "<" ++ celltype ++ " align=\"" ++ align' ++ "\">" ++
                    x ++ "</" ++ celltype ++ ">"
  contents <- blockListToCustom opts item
  return $ mkcell contents
-}

-- | Convert list of Pandoc block elements to Custom.
blockListToCustom :: LuaState -- ^ Options
                  -> [Block]       -- ^ List of block elements
                  -> IO ByteString
blockListToCustom lua xs = do
  blocksep <- callfunc lua "Blocksep"
  bs <- mapM (blockToCustom lua) xs
  return $ mconcat $ intersperse blocksep bs

-- | Convert list of Pandoc inline elements to Custom.
inlineListToCustom :: LuaState -> [Inline] -> IO ByteString
inlineListToCustom lua lst = do
  xs <- mapM (inlineToCustom lua) lst
  return $ C8.concat xs

-- | Convert Pandoc inline element to Custom.
inlineToCustom :: LuaState -> Inline -> IO ByteString

inlineToCustom lua (Str str) =
  callfunc lua "Str" $ fromString str

inlineToCustom lua Space =
  callfunc lua "Space"

inlineToCustom lua (Emph lst) = do
  x <- inlineListToCustom lua lst
  callfunc lua "Emph" x

inlineToCustom lua (Strong lst) = do
  x <- inlineListToCustom lua lst
  callfunc lua "Strong" x

inlineToCustom lua (Strikeout lst) = do
  x <- inlineListToCustom lua lst
  callfunc lua "Strikeout" x

inlineToCustom lua (Superscript lst) = do
  x <- inlineListToCustom lua lst
  callfunc lua "Superscript" x

inlineToCustom lua (Subscript lst) = do
  x <- inlineListToCustom lua lst
  callfunc lua "Subscript" x

inlineToCustom lua (SmallCaps lst) = do
  x <- inlineListToCustom lua lst
  callfunc lua "SmallCaps" x

inlineToCustom lua (Quoted SingleQuote lst) = do
  x <- inlineListToCustom lua lst
  callfunc lua "SingleQuoted" x

inlineToCustom lua (Quoted DoubleQuote lst) = do
  x <- inlineListToCustom lua lst
  callfunc lua "DoubleQuoted" x

inlineToCustom lua (Cite _  lst) = do
  x <- inlineListToCustom lua lst
  callfunc lua "Cite" x

inlineToCustom lua (Code (id',classes,keyvals) str) =
  callfunc lua "Code" (fromString str) (fromString id')
      (map fromString classes)
      (map (\(k,v) -> (fromString k, fromString v)) keyvals)

inlineToCustom lua (Math DisplayMath str) =
  callfunc lua "DisplayMath" (fromString str)

inlineToCustom lua (Math InlineMath str) =
  callfunc lua "InlineMath" (fromString str)

inlineToCustom lua (RawInline format str) =
  callfunc lua "RawInline" format (fromString str)

inlineToCustom lua (LineBreak) =
  callfunc lua "LineBreak"

inlineToCustom lua (Link txt (src,tit)) = do
  label <- inlineListToCustom lua txt
  callfunc lua "Link" label (fromString src) (fromString tit)

inlineToCustom lua (Image alt (src,tit)) = do
  alt' <- inlineListToCustom lua alt
  callfunc lua "Image" alt' (fromString src) (fromString tit)

inlineToCustom lua (Note contents) = do
  contents' <- blockListToCustom lua contents
  callfunc lua "Note" contents'
