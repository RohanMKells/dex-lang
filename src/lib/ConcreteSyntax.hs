-- Copyright 2022 Google LLC
--
-- Use of this source code is governed by a BSD-style
-- license that can be found in the LICENSE file or at
-- https://developers.google.com/open-source/licenses/bsd

module ConcreteSyntax (
  mustParseit, sourceBlocks, sourceBlock,
  keyWordStrs, showPrimName,
  parseUModule, parseUModuleDeps,
  finishUModuleParse, preludeImportBlock, mustParseSourceBlock,
  pattern ExprBlock,
  pattern Binary, pattern Prefix, pattern Postfix, pattern Identifier) where

import Control.Monad.Combinators.Expr qualified as Expr
import Control.Monad.Reader
import Data.Char
import Data.Functor
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map qualified as M
import Data.String (fromString)
import Data.Text (Text)
import Data.Text          qualified as T
import Data.Text.Encoding qualified as T
import Data.Tuple
import Data.Void
import Text.Megaparsec hiding (Label, State)
import Text.Megaparsec.Char hiding (space, eol)

import Err
import Lexing
import Name
import Types.Core
import Types.Source
import Types.Primitives
import Util

-- TODO: implement this more efficiently rather than just parsing the whole
-- thing and then extracting the deps.
parseUModuleDeps :: ModuleSourceName -> File -> [ModuleSourceName]
parseUModuleDeps name file = deps
  where UModule _ deps _ = parseUModule name $ T.decodeUtf8 $ fContents file
{-# SCC parseUModuleDeps #-}

finishUModuleParse :: UModulePartialParse -> UModule
finishUModuleParse (UModulePartialParse name _ file) =
  parseUModule name (T.decodeUtf8 $ fContents file)

parseUModule :: ModuleSourceName -> Text -> UModule
parseUModule name s = do
  let blocks = mustParseit s sourceBlocks
  let preamble = case name of
        Prelude -> []
        _ -> [preludeImportBlock]
  let blocks' = preamble ++ blocks
  let imports = flip foldMap blocks' \b -> case sbContents b of
                  Misc (ImportModule moduleName) -> [moduleName]
                  _ -> []
  UModule name imports blocks'
{-# SCC parseUModule #-}

preludeImportBlock :: SourceBlock
preludeImportBlock = SourceBlock 0 0 LogNothing "" $ Misc $ ImportModule Prelude

sourceBlocks :: Parser [SourceBlock]
sourceBlocks = manyTill (sourceBlock <* outputLines) eof
{-# SCC sourceBlocks #-}

mustParseSourceBlock :: Text -> SourceBlock
mustParseSourceBlock s = mustParseit s sourceBlock

-- === helpers for target ADT ===

interp_operator :: String -> Bin'
interp_operator = \case
  "&>"  -> DepAmpersand
  "."   -> Dot
  ",>"  -> DepComma
  ":"   -> Colon
  "|"   -> Pipe
  "::"  -> DoubleColon
  "$"   -> Dollar
  "->>" -> ImplicitArrow
  "=>"  -> FatArrow
  "="   -> CSEqual
  name  -> EvalBinOp $ "(" <> name <> ")"

pattern ExprBlock :: Group -> CSBlock
pattern ExprBlock g <- (CSBlock [WithSrc _ (CExpr g)]) where
  ExprBlock g = CSBlock [WithSrc Nothing (CExpr g)]

pattern Binary :: Bin' -> Group -> Group -> Group
pattern Binary op lhs rhs <- (WithSrc _ (CBin (WithSrc _ op) lhs rhs)) where
  Binary op lhs rhs = joinSrc lhs rhs $ CBin (WithSrc Nothing op) lhs rhs

pattern Prefix :: SourceName -> Group -> Group
pattern Prefix op g <- (WithSrc _ (CPrefix op g)) where
  Prefix op g = WithSrc Nothing $ CPrefix op g

pattern Postfix :: SourceName -> Group -> Group
pattern Postfix op g <- (WithSrc _ (CPostfix op g)) where
  Postfix op g = WithSrc Nothing $ CPostfix op g

pattern Identifier :: SourceName -> Group
pattern Identifier name <- (WithSrc _ (CIdentifier name)) where
  Identifier name = WithSrc Nothing $ CIdentifier name

-- === Parser (top-level structure) ===

sourceBlock :: Parser SourceBlock
sourceBlock = do
  offset <- getOffset
  pos <- getSourcePos
  (src, (level, b)) <- withSource $ withRecovery recover $ do
    level <- logLevel <|> logTime <|> logBench <|> return LogNothing
    b <- sourceBlock'
    return (level, b)
  return $ SourceBlock (unPos (sourceLine pos)) offset level src b

recover :: ParseError Text Void -> Parser (LogLevel, SourceBlock')
recover e = do
  pos <- liftM statePosState getParserState
  reachedEOF <-  try (mayBreak sc >> eof >> return True)
             <|> return False
  consumeTillBreak
  let errmsg = errorBundlePretty (ParseErrorBundle (e :| []) pos)
  return (LogNothing, UnParseable reachedEOF errmsg)

importModule :: Parser SourceBlock'
importModule = Misc . ImportModule . OrdinaryModule <$> do
  keyWord ImportKW
  s <- anyCaseName
  eol
  return s

declareForeign :: Parser SourceBlock'
declareForeign = do
  keyWord ForeignKW
  foreignName <- strLit
  b <- lowerName
  void $ label "type annotation" $ sym ":"
  ty <- cGroup
  eol
  return $ DeclareForeign foreignName b ty

declareCustomLinearization :: Parser SourceBlock'
declareCustomLinearization = do
  zeros <- (keyWord CustomLinearizationSymbolicKW $> SymbolicZeros)
       <|> (keyWord CustomLinearizationKW $> InstantiateZeros)
  fun <- anyCaseName
  linearization <- cGroup
  eol
  return $ DeclareCustomLinearization fun zeros linearization

consumeTillBreak :: Parser ()
consumeTillBreak = void $ manyTill anySingle $ eof <|> void (try (eol >> eol))

logLevel :: Parser LogLevel
logLevel = do
  void $ try $ lexeme $ char '%' >> string "passes"
  passes <- many passName
  eol
  case passes of
    [] -> return LogAll
    _ -> return $ LogPasses passes

logTime :: Parser LogLevel
logTime = do
  void $ try $ lexeme $ char '%' >> string "time"
  eol
  return PrintEvalTime

logBench :: Parser LogLevel
logBench = do
  void $ try $ lexeme $ char '%' >> string "bench"
  benchName <- strLit
  eol
  return $ PrintBench benchName

passName :: Parser PassName
passName = choice [thisNameString s $> x | (s, x) <- passNames]

passNames :: [(Text, PassName)]
passNames = [(T.pack $ show x, x) | x <- [minBound..maxBound]]

sourceBlock' :: Parser SourceBlock'
sourceBlock' =
      proseBlock
  <|> topLevelCommand
  <|> liftM TopDecl (dataDef <* eolf)
  <|> liftM TopDecl (structDef <* eolf)
  <|> liftM TopDecl (topInstanceDecl <* eolf)
  <|> liftM TopDecl (interfaceDef <* eolf)
  <|> liftM TopDecl (effectDef <* eolf)
  <|> topLetOrExpr <* eolf
  <|> hidden (some eol >> return (Misc EmptyLines))
  <|> hidden (sc >> eol >> return (Misc CommentLine))

proseBlock :: Parser SourceBlock'
proseBlock = label "prose block" $ char '\'' >> fmap (Misc . ProseBlock . fst) (withSource consumeTillBreak)

topLevelCommand :: Parser SourceBlock'
topLevelCommand =
      importModule
  <|> declareForeign
  <|> declareCustomLinearization
  <|> (Misc . QueryEnv <$> envQuery)
  <|> explicitCommand
  <?> "top-level command"

envQuery :: Parser EnvQuery
envQuery = string ":debug" >> sc >> (
      (DumpSubst        <$  (string "env"   >> sc))
  <|> (InternalNameInfo <$> (string "iname" >> sc >> rawName))
  <|> (SourceNameInfo   <$> (string "sname" >> sc >> anyName)))
       <* eol
  where
    rawName :: Parser RawName
    rawName = undefined -- RawName <$> (fromString <$> anyName) <*> intLit

explicitCommand :: Parser SourceBlock'
explicitCommand = do
  cmdName <- char ':' >> nameString
  cmd <- case cmdName of
    "p"       -> return $ EvalExpr (Printed Nothing)
    "pp"      -> return $ EvalExpr (Printed (Just PrintHaskell))
    "pcodegen"-> return $ EvalExpr (Printed (Just PrintCodegen))
    "t"       -> return $ GetType
    "html"    -> return $ EvalExpr RenderHtml
    "export"  -> ExportFun <$> nameString
    _ -> fail $ "unrecognized command: " ++ show cmdName
  e <- cBlock <* eolf
  return $ case (e, cmd) of
    (ExprBlock (WithSrc _ (CIdentifier v)), GetType) -> Misc $ GetNameType v
    _ -> Command cmd e

structDef :: Parser CTopDecl
structDef = withSrc do
  keyWord StructKW
  tyName <- anyName
  (params, givens) <- typeParams
  fields <- onePerLine nameAndType
  return $ CStruct tyName params givens fields

dataDef :: Parser CTopDecl
dataDef = withSrc do
  keyWord DataKW
  tyName <- anyName
  (params, givens) <- typeParams
  dataCons <- onePerLine do
    dataConName <- anyName
    dataConArgs <- optExplicitParams
    return (dataConName, dataConArgs)
  return $ CData tyName params givens dataCons

topInstanceDecl :: Parser CTopDecl
topInstanceDecl = withSrc $ liftM (CSDecl PlainLet) $
      (CInstanceDecl <$> instanceDef True)
  <|> (CInstanceDecl <$> instanceDef False)

interfaceDef :: Parser CTopDecl
interfaceDef = withSrc do
  keyWord InterfaceKW
  className <- anyName
  params <- explicitParams
  methodDecls <- try (withIndent (keyWord PassKW) >> return [])
    <|> onePerLine do
      methodName <- anyName
      void $ label "type annotation" $ sym ":"
      ty <- cGroup
      return (methodName, ty)
  return $ CInterface className params methodDecls

effectDef :: Parser CTopDecl
effectDef = withSrc do
  keyWord EffectKW
  effName <- anyName
  sigs <- opSigList
  return $ CEffectDecl (fromString effName) sigs

opSigList :: Parser [(SourceName, UResumePolicy, Group)]
opSigList = onePerLine do
  policy <- resumePolicy
  v <- anyName
  void $ sym ":"
  ty <- cGroup
  return (fromString v, policy, ty)

resumePolicy :: Parser UResumePolicy
resumePolicy =  (keyWord JmpKW $> UNoResume)
            <|> (keyWord DefKW $> ULinearResume)
            <|> (keyWord CtlKW $> UAnyResume)

nameAndType :: Parser (SourceName, Group)
nameAndType = do
  n <- anyName
  sym ":"
  arg <- cGroup
  return (n, arg)

topLetOrExpr :: Parser SourceBlock'
topLetOrExpr = withSrc topLet >>= \case
  WithSrc _ (CSDecl ann (CExpr e)) -> do
    when (ann /= PlainLet) $ fail "Cannot annotate expressions"
    return $ Command (EvalExpr (Printed Nothing)) (ExprBlock e)
  d -> return $ TopDecl d

topLet :: Parser CTopDecl'
topLet = do
  lAnn <- (char '@' >> letAnnStr <* (eol <|> sc)) <|> return PlainLet
  decl <- cDecl
  return $ CSDecl lAnn decl
  where
    letAnnStr :: Parser LetAnn
    letAnnStr = (string "noinline"   $> NoInlineLet)

onePerLine :: Parser a -> Parser [a]
onePerLine p =   liftM (:[]) p
             <|> (withIndent $ mayNotBreak $ p `sepBy1` try nextLine)
{-# INLINE onePerLine #-}

-- === Groups ===

-- Parse a block, which could also just be a group
cBlock :: Parser CSBlock
cBlock = cBlock' >>= \case
  Left blk -> return blk
  Right ex -> return $ ExprBlock ex

-- Parse a block or a group but tell me which (i.e., whether it was indented or not)
cBlock' :: Parser (Either CSBlock Group)
cBlock' = Left <$> realBlock <|> Right <$> cGroup where

realBlock :: Parser CSBlock
realBlock = withIndent $
  CSBlock <$> (mayNotBreak $ withSrc cDecl `sepBy1` (semicolon <|> try nextLine))

cDecl :: Parser CSDecl'
cDecl =   (CInstanceDecl <$> instanceDef True)
      <|> (CDefDecl <$> funDefLet)
      <|> simpleLet
      <|> (keyWord PassKW >> return CPass)

simpleLet :: Parser CSDecl'
simpleLet = do
  lhs <- cGroupNoEqual
  next <- nextChar
  case next of
    '=' -> sym  "=" >> CLet  lhs <$> cBlock
    '<' -> sym "<-" >> CBind lhs <$> cBlock
    _   -> return $ CExpr lhs

instanceDef :: Bool -> Parser CInstanceDef
instanceDef isNamed = do
  optNameAndArgs <- case isNamed of
    False -> keyWord InstanceKW $> Nothing
    True  -> keyWord NamedInstanceKW >> do
      name <- fromString <$> anyName
      args <-  (sym ":" >> return Nothing)
           <|> ((Just <$> parens (commaSep cParenGroup)) <* sym "->")
      return $ Just (name, args)
  className <- anyName
  args <- argList
  givens <- optional givenClause
  methods <- realBlock
  return $ CInstanceDef className args givens methods optNameAndArgs

funDefLet :: Parser CDef
funDefLet = label "function definition" do
  keyWord DefKW
  mayBreak do
    name   <- anyName
    params <- explicitParams
    rhs    <- optional do
      expl     <- explicitness
      effs     <- optional cEffs
      resultTy <- cGroupNoEqual
      return (expl, effs, resultTy)
    givens <- optional givenClause
    mayNotBreak do
      sym "="
      body <- cBlock
      return $ CDef name params rhs givens body

explicitness :: Parser AppExplicitness
explicitness =   (sym "->"  $> ExplicitApp)
             <|> (sym "->>" $> ImplicitApp)

-- Intended for occurrences, like `foo(x, y, z)` (cf. defParamsList).
argList :: Parser [Group]
argList = immediateParens (commaSep cParenGroup)

immediateLParen :: Parser ()
immediateLParen = label "'(' (without preceding whitespace)" do
  nextChar >>= \case
    '(' -> precededByWhitespace >>= \case
      True -> empty
      False -> charLexeme '('
    _ -> empty

immediateParens :: Parser a -> Parser a
immediateParens p = bracketed immediateLParen rParen p

-- Putting `sym =` inside the cases gives better errors.
typeParams :: Parser (ExplicitParams, Maybe GivenClause)
typeParams =
      (explicitParamsAndGivens <* sym "=")
  <|> (return ([], Nothing)    <* sym "=")

explicitParamsAndGivens :: Parser (ExplicitParams, Maybe GivenClause)
explicitParamsAndGivens = (,) <$> explicitParams <*> optional givenClause

optExplicitParams :: Parser ExplicitParams
optExplicitParams = label "optional parameter list" $
  explicitParams <|> return []

explicitParams :: Parser ExplicitParams
explicitParams = label "parameter list in parentheses (without preceding whitespace)" $
  immediateParens $ commaSep cParenGroup

noGap :: Parser ()
noGap = precededByWhitespace >>= \case
  True -> fail "Unexpected whitespace"
  False -> return ()

givenClause :: Parser GivenClause
givenClause = keyWord GivenKW >> do
  (,) <$> parens (commaSep cGroup)
      <*> optional (parens (commaSep cGroup))

arrowOptEffs :: Parser (Maybe CEffs)
arrowOptEffs = sym "->" >> optional cEffs

cEffs :: Parser CEffs
cEffs = braces do
  effs <- commaSep cGroupNoPipe
  effTail <- optional $ sym "|" >> cGroup
  return (effs, effTail)

commaSep :: Parser a -> Parser [a]
commaSep p = p `sepBy` sym ","

cParenGroup :: Parser Group
cParenGroup = withSrc (CGivens <$> givenClause) <|> cGroup

cGroup :: Parser Group
cGroup = makeExprParser leafGroup ops

cGroupNoJuxt :: Parser Group
cGroupNoJuxt = makeExprParser leafGroup $
  withoutOp "space" $ withoutOp "." ops

cGroupNoEqual :: Parser Group
cGroupNoEqual = makeExprParser leafGroup $
  withoutOp "=" ops

cGroupNoPipe :: Parser Group
cGroupNoPipe = makeExprParser leafGroup $
  withoutOp "|" ops

cGroupNoArrow :: Parser Group
cGroupNoArrow = makeExprParser leafGroup $
  withoutOp "->" ops

cNullaryLam :: Parser Group'
cNullaryLam = do
  sym "\\."
  body <- cBlock
  return $ CLambda [] body

cLam :: Parser Group'
cLam = do
  sym "\\"
  bs <- many cGroupNoJuxt
  mayNotBreak $ sym "."
  body <- cBlock
  return $ CLambda bs body

cFor :: Parser Group'
cFor = do
  kw <- forKW
  indices <- many cGroupNoJuxt
  mayNotBreak $ sym "."
  body <- cBlock
  return $ CFor kw indices body
  where forKW =     keyWord ForKW  $> KFor
                <|> keyWord For_KW $> KFor_
                <|> keyWord RofKW  $> KRof
                <|> keyWord Rof_KW $> KRof_

cDo :: Parser Group'
cDo = keyWord DoKW >> CDo <$> cBlock

cCase :: Parser Group'
cCase = do
  keyWord CaseKW
  scrut <- cGroup
  keyWord OfKW
  alts <- onePerLine $ (,) <$> cGroupNoArrow <*> (sym "->" *> cBlock)
  return $ CCase scrut alts

-- We support the following syntaxes for `if`:
-- - 1-armed then-newline
--     if predicate
--       then consequent
--     if predicate
--       then
--         consequent1
--         consequent2
-- - 2-armed then-newline else-newline
--     if predicate
--       then consequent
--       else alternate
--   and the three other versions where the consequent or the
--   alternate are themselves blocks
-- - 1-armed then-inline
--     if predicate then consequent
--     if predicate then
--       consequent1
--       consequent2
-- - 2-armed then-inline else-inline
--     if predicate then consequent else alternate
--     if predicate then consequent else
--       alternate1
--       alternate2
-- - Notably, an imagined 2-armed then-inline else-newline
--     if predicate then
--       consequent1
--       consequent2
--     else alternate
--   is not an option, because the indentation lines up badly.  To wit,
--   one would want the `else` to be indented relative to the `if`,
--   but outdented relative to the consequent block, and if the `then` is
--   inline there is no indentation level that does that.
-- - Last candiate is
--      if predicate
--        then consequent else alternate
--      if predicate
--        then consequent else
--          alternate1
--          alternate2
cIf :: Parser Group'
cIf = mayNotBreak do
  keyWord IfKW
  predicate <- cGroup
  (cons, alt) <- thenSameLine <|> thenNewLine
  return $ CIf predicate cons alt

thenSameLine :: Parser (CSBlock, Maybe CSBlock)
thenSameLine = do
  keyWord ThenKW
  cBlock' >>= \case
    (Left blk) -> do
      let msg = ("No `else` may follow same-line `then` and indented consequent"
                  ++ "; indent and align both `then` and `else`, or write the "
                  ++ "whole `if` on one line.")
      mayBreak $ noElse msg
      return (blk, Nothing)
    (Right ex) -> do
      alt <- optional
        $ (keyWord ElseKW >> cBlock)
          <|> (lookAhead (try $ withIndent (mayNotBreak $ keyWord ElseKW))
               >> withIndent (mayNotBreak $ keyWord ElseKW >> cBlock))
      return (ExprBlock ex, alt)

thenNewLine :: Parser (CSBlock, Maybe CSBlock)
thenNewLine = withIndent $ mayNotBreak $ do
  keyWord ThenKW
  cBlock' >>= \case
    (Left blk) -> do
      alt <- do
        -- With `mayNotBreak`, this just forbids inline else
        noElse ("Same-line `else` may not follow indented consequent;"
                ++ " put the `else` on the next line.")
        optional $ do
          try $ nextLine >> keyWord ElseKW
          cBlock
      return (blk, alt)
    (Right ex) -> do
      void $ optional $ try nextLine
      alt <- optional $ keyWord ElseKW >> cBlock
      return (ExprBlock ex, alt)

noElse :: String -> Parser ()
noElse msg = (optional $ try $ sc >> keyWord ElseKW) >>= \case
  Just () -> fail msg
  Nothing -> return ()

leafGroup :: Parser Group
leafGroup = do
  leaf <- leafGroup'
  postOps <- many postfixGroup
  return $ foldl (\accum (op, opLhs) -> joinSrc accum opLhs $ CBin (WithSrc Nothing op) accum opLhs) leaf postOps
 where

  leafGroup' :: Parser Group
  leafGroup' = withSrc do
    next <- nextChar
    case next of
      '_'  ->  underscore $> CHole
      '('  ->  (CIdentifier <$> symName)
           <|> cParens
      '['  -> cBrackets
      '{'  -> cBraces
      '\"' -> CString <$> strLit
      '\'' -> CChar <$> charLit
      '%'  -> do
        name <- primName
        case strToPrimName name of
          Just prim -> CPrim prim <$> argList
          Nothing   -> fail $ "Unrecognized primitive: " ++ name
      _ | isDigit next -> (    CNat   <$> natLit
                           <|> CFloat <$> doubleLit)
      '\\' -> cNullaryLam <|> cLam
      -- For exprs include for, rof, for_, rof_
      'f'  -> cFor  <|> cIdentifier
      'd'  -> cDo   <|> cIdentifier
      'r'  -> cFor  <|> cIdentifier
      'c'  -> cCase <|> cIdentifier
      'i'  -> cIf   <|> cIdentifier
      _    -> cIdentifier

  postfixGroup :: Parser (Bin', Group)
  postfixGroup = noGap >>
        ((JuxtaposeNoSpace,) <$> withSrc cParens)
    <|> ((JuxtaposeNoSpace,) <$> withSrc cBrackets)
    <|> ((Dot,)              <$> (try $ char '.' >> withSrc cIdentifier))

cIdentifier :: Parser Group'
cIdentifier = CIdentifier <$> anyName

cParens :: Parser Group'
cParens = CParens <$> parens (commaSep cParenGroup)

cBrackets :: Parser Group'
cBrackets = CBrackets <$> brackets (commaSep cGroup)

cBraces :: Parser Group'
cBraces = CBrackets <$> braces (commaSep cGroup)

-- A `PrecTable` is enough information to (i) remove or replace
-- operators for special contexts, and (ii) build the input structure
-- for Expr.makeExprParser.
type PrecTable a = [[(SourceName, Expr.Operator Parser a)]]

makeExprParser :: Parser a -> PrecTable a -> Parser a
makeExprParser p tbl = Expr.makeExprParser p tbl' where
  tbl' = map (map snd) tbl

withoutOp :: SourceName -> PrecTable a -> PrecTable a
withoutOp op tbl = map (filter ((/= op) . fst)) tbl

ops :: PrecTable Group
ops =
  [ [symOpL   "!"]
  , [juxtaposition]
  , [unOpPre  "-", unOpPre  "+"]
  , [backquote]
  -- Other ops with default fixity
  , [other]
  , [symOpL   "*", symOpL   "/"]
  , [symOpL  ".*", symOpL  "*."]
  , [symOpL ".**", symOpL "**."]
  , [symOpL  "**"]
  , [symOpL   "+", symOpL   "-"]
  , [symOpL  "-|"]
  , [symOpL "+>>"]
  , [symOpL  "<>"]
  , [symOpN  "~~"]
  , [symOpN   "<", symOpN  "<=", symOpN ">", symOpN ">="]
  , [symOpN  "==", symOpN  "!="]
  , [symOpL  "&&"]
  , [symOpL  "||"]
  , [unOpPre "..", unOpPre "..<", unOpPost "..", unOpPost "<.."]
  , [symOpR  "=>"]
  , [arrow, symOpR "->>"]
  , [symOpL ">>>"]
  , [symOpL "<<<"]
  , [symOpL "&>>"]
  , [symOpL "<<&"]
  , [symOpL   "@"]
  , [unOpPre  "@"]
  , [unOpPre "@..."]
  , [unOpPre "..."]
  , [symOpN  "::"]
  , [symOpR   "$"]
  , [symOpN  "+=", symOpN  ":="]
  -- Associate right so the mistaken utterance foo : i:Fin 4 => (..i)
  -- groups as a bad pi type rather than a bad binder
  , [symOpR   ":"]
  , [symOpL   "|"]
  , [symOpR  ",>"]
  , [symOpR  "&>"]
  , [symOpL   "="]
  ] where
  other = ("other", anySymOp)
  backquote = ("backquote", Expr.InfixL $ opWithSrc $ backquoteName >>= (return . binApp . EvalBinOp))
  juxtaposition  = ("space", Expr.InfixL $ opWithSrc $ sc $> (binApp JuxtaposeWithSpace))
  arrow = ("->", Expr.InfixR arrowOp)

opWithSrc :: Parser (SrcPos -> a -> a -> a)
          -> Parser (a -> a -> a)
opWithSrc p = do
  (f, pos) <- withPos p
  return $ f pos
{-# INLINE opWithSrc #-}

anySymOp :: Expr.Operator Parser Group
anySymOp = Expr.InfixL $ opWithSrc $ do
  s <- label "infix operator" (mayBreak anySym)
  return $ binApp $ interp_operator s

infixSym :: SourceName -> Parser ()
infixSym s = mayBreak $ sym $ T.pack s

symOpN :: SourceName -> (SourceName, Expr.Operator Parser Group)
symOpN s = (s, Expr.InfixN $ symOp s)

symOpL :: SourceName -> (SourceName, Expr.Operator Parser Group)
symOpL s = (s, Expr.InfixL $ symOp s)

symOpR :: SourceName -> (SourceName, Expr.Operator Parser Group)
symOpR s = (s, Expr.InfixR $ symOp s)

symOp :: SourceName -> Parser (Group -> Group -> Group)
symOp s = opWithSrc $ do
  label "infix operator" (infixSym s)
  return $ binApp $ interp_operator s

arrowOp :: Parser (Group -> Group -> Group)
arrowOp = do
  WithSrc src effs <- withSrc arrowOptEffs
  return \lhs rhs -> WithSrc src $ CArrow lhs effs rhs

unOpPre :: SourceName -> (SourceName, Expr.Operator Parser Group)
unOpPre s = (s, Expr.Prefix $ unOp CPrefix s)

unOpPost :: SourceName -> (SourceName, Expr.Operator Parser Group)
unOpPost s = (s, Expr.Postfix $ unOp CPostfix s)

unOp :: (SourceName -> Group -> Group') -> SourceName -> Parser (Group -> Group)
unOp f s = do
  ((), pos) <- withPos $ sym $ fromString s
  return \g@(WithSrc grpPos _) -> WithSrc (joinPos (Just pos) grpPos) $ f s g

binApp :: Bin' -> SrcPos -> Group -> Group -> Group
binApp f pos x y = joinSrc3 f' x y $ CBin f' x y
  where f' = WithSrc (Just pos) f

withSrc :: Parser a -> Parser (WithSrc a)
withSrc p = do
  (x, pos) <- withPos p
  return $ WithSrc (Just pos) x

joinSrc :: WithSrc a1 -> WithSrc a2 -> a3 -> WithSrc a3
joinSrc (WithSrc p1 _) (WithSrc p2 _) x = WithSrc (joinPos p1 p2) x

joinSrc3 :: WithSrc a1 -> WithSrc a2 -> WithSrc a3 -> a4 -> WithSrc a4
joinSrc3 (WithSrc p1 _) (WithSrc p2 _) (WithSrc p3 _) x =
  WithSrc (concatPos [p1, p2, p3]) x

joinPos :: Maybe SrcPos -> Maybe SrcPos -> Maybe SrcPos
joinPos Nothing p = p
joinPos p Nothing = p
joinPos (Just (l, h)) (Just (l', h')) = Just (min l l', max h h')

concatPos :: [Maybe SrcPos] -> Maybe SrcPos
concatPos [] = Nothing
concatPos (pos:rest) = foldl joinPos pos rest

-- === primitive constructors and operators ===

strToPrimName :: String -> Maybe PrimName
strToPrimName s = M.lookup s primNames

primNameToStr :: PrimName -> String
primNameToStr prim = case lookup prim $ map swap $ M.toList primNames of
  Just s  -> s
  Nothing -> show prim

showPrimName :: PrimName -> String
showPrimName prim = primNameToStr prim
{-# NOINLINE showPrimName #-}

primNames :: M.Map String PrimName
primNames = M.fromList
  [ ("ask"      , UMAsk), ("mextend", UMExtend)
  , ("get"      , UMGet), ("put"    , UMPut)
  , ("while"    , UWhile)
  , ("linearize", ULinearize), ("linearTranspose", UTranspose)
  , ("runReader", URunReader), ("runWriter"      , URunWriter), ("runState", URunState)
  , ("runIO"    , URunIO    ), ("catchException" , UCatchException)
  , ("iadd" , binary IAdd),  ("isub"  , binary ISub)
  , ("imul" , binary IMul),  ("fdiv"  , binary FDiv)
  , ("fadd" , binary FAdd),  ("fsub"  , binary FSub)
  , ("fmul" , binary FMul),  ("idiv"  , binary IDiv)
  , ("irem" , binary IRem)
  , ("fpow" , binary FPow)
  , ("and"  , binary BAnd),  ("or"    , binary BOr )
  , ("not"  , unary  BNot),  ("xor"   , binary BXor)
  , ("shl"  , binary BShL),  ("shr"   , binary BShR)
  , ("ieq"  , binary (ICmp Equal)),   ("feq", binary (FCmp Equal))
  , ("igt"  , binary (ICmp Greater)), ("fgt", binary (FCmp Greater))
  , ("ilt"  , binary (ICmp Less)),    ("flt", binary (FCmp Less))
  , ("fneg" , unary  FNeg)
  , ("exp"  , unary  Exp),   ("exp2"  , unary Exp2)
  , ("log"  , unary  Log),   ("log2"  , unary Log2), ("log10" , unary Log10)
  , ("sin"  , unary  Sin),   ("cos"   , unary Cos)
  , ("tan"  , unary  Tan),   ("sqrt"  , unary Sqrt)
  , ("floor", unary  Floor), ("ceil"  , unary Ceil), ("round", unary Round)
  , ("log1p", unary  Log1p), ("lgamma", unary LGamma)
  , ("erf"  , unary Erf),    ("erfc"  , unary Erfc)
  , ("TyKind"    , UPrimTC $ TypeKind)
  , ("Float64"   , baseTy $ Scalar Float64Type)
  , ("Float32"   , baseTy $ Scalar Float32Type)
  , ("Int64"     , baseTy $ Scalar Int64Type)
  , ("Int32"     , baseTy $ Scalar Int32Type)
  , ("Word8"     , baseTy $ Scalar Word8Type)
  , ("Word32"    , baseTy $ Scalar Word32Type)
  , ("Word64"    , baseTy $ Scalar Word64Type)
  , ("Int32Ptr"  , baseTy $ ptrTy $ Scalar Int32Type)
  , ("Word8Ptr"  , baseTy $ ptrTy $ Scalar Word8Type)
  , ("Word32Ptr" , baseTy $ ptrTy $ Scalar Word32Type)
  , ("Word64Ptr" , baseTy $ ptrTy $ Scalar Word64Type)
  , ("Float32Ptr", baseTy $ ptrTy $ Scalar Float32Type)
  , ("PtrPtr"    , baseTy $ ptrTy $ ptrTy $ Scalar Word8Type)
  , ("Nat"           , UNat)
  , ("Fin"           , UFin)
  , ("Label"         , ULabelType)
  , ("EffKind"       , UEffectRowKind)
  , ("LabeledRowKind", ULabeledRowKind)
  , ("NatCon"        , UNatCon)
  , ("Ref"       , UPrimTC $ RefType () ())
  , ("HeapType"  , UPrimTC $ HeapType)
  , ("fstRef"     , UProjRef 0)
  , ("sndRef"     , UProjRef 1)
  , ("indexRef"   , UIndexRef)
  , ("alloc"    , memOp $ IOAlloc (Scalar Word8Type) ())
  , ("free"     , memOp $ IOFree ())
  , ("ptrOffset", memOp $ PtrOffset () ())
  , ("ptrLoad"  , memOp $ PtrLoad ())
  , ("ptrStore" , memOp $ PtrStore () ())
  , ("throwError"    , miscOp $ ThrowError ())
  , ("throwException", miscOp $ ThrowException ())
  , ("dataConTag"    , miscOp $ SumTag ())
  , ("toEnum"        , miscOp $ ToEnum () ())
  , ("outputStream"  , miscOp $ OutputStream)
  , ("cast"          , miscOp $ CastOp () ())
  , ("bitcast"       , miscOp $ BitcastOp () ())
  , ("unsafeCoerce"  , miscOp $ UnsafeCoerce () ())
  , ("garbageVal"    , miscOp $ GarbageVal ())
  , ("select"        , miscOp $ Select () () ())
  , ("showAny"       , miscOp $ ShowAny ())
  , ("showScalar"    , miscOp $ ShowScalar ())
  , ("projNewtype" , UProjNewtype)
  , ("applyMethod0" , UApplyMethod 0)
  , ("applyMethod1" , UApplyMethod 1)
  , ("applyMethod2" , UApplyMethod 2)
  , ("pair"         , UPrimCon $ ProdCon [(), ()])
  , ("explicitApply", UExplicitApply)
  , ("monoLit", UMonoLiteral)
  ]
  where
    binary op = UPrimOp $ BinOp op () ()
    baseTy b = UPrimTC $ BaseType b
    memOp op = UPrimOp $ MemOp op
    unary  op = UPrimOp $ UnOp  op ()
    ptrTy  ty = PtrType (CPU, ty)
    miscOp op = UPrimOp $ MiscOp op
