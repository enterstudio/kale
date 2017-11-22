{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE TypeSynonymInstances #-}

module Kale where

import           Control.Applicative
import           Control.Monad
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Maybe (MaybeT(..))
import           Data.Char                 (isAlphaNum, isLower, isSpace,
                                            isUpper, toUpper)
import           Data.List                 (foldl', groupBy, intercalate, sort,
                                            stripPrefix, isPrefixOf, find)
import           Data.Maybe                (catMaybes)
import           System.Directory          (doesDirectoryExist, doesFileExist,
                                            getDirectoryContents)
import           System.Environment        (getArgs)
import           System.FilePath

data TaskArgs = NoArgs | PositionalArgs String | RecordArgs String deriving (Eq, Show)
newtype TaskModule = TaskModule { unTaskModule :: String } deriving (Eq, Show)
newtype TaskName = TaskName { unTaskName :: String } deriving (Eq, Show)

data Task = Task
    { taskModule :: TaskModule
    -- ^ The name of the task module.
    , taskArgs   :: TaskArgs
    -- ^ The arguments to provide to the task.
    , taskName   :: TaskName
    -- ^ The name of the task.
    }
    deriving (Eq, Show)

-- | 'runKale' is the entry point of the Kale task discovery tool.
runKale :: IO ()
runKale = do
    kaleArgs <- getArgs
    case kaleArgs of
        src : _ : dest : _ -> do
            tasks <- findTasks src
            writeTaskModule dest (mkTaskModule src tasks)
        _ -> do
            putStrLn usage
            print kaleArgs

newtype TaskModuleContents = TaskModuleContents { unTaskModuleContents :: String }

writeTaskModule :: FilePath -> TaskModuleContents -> IO ()
writeTaskModule dest taskModuleContents = writeFile dest (unTaskModuleContents taskModuleContents)

mkTaskModule :: FilePath -> [Task] -> TaskModuleContents
mkTaskModule src tasks = TaskModuleContents $ unlines
  [ "{-# LINE 1 " ++ show src ++ " #-}"
  , "{-# OPTIONS_GHC -fno-warn-warnings-deprecations #-}\n"
  , "{-# LANGUAGE DeriveGeneric #-}"
  , "{-# LANGUAGE DeriveAnyClass #-}"
  , "{-# LANGUAGE OverloadedStrings #-}"
  , "{-# LANGUAGE RecordWildCards #-}"
  , ""
  , "module " ++ pathToModule src ++ " where"
  , ""
  , "import Kale.Discover"
  , unImportList $ importList tasks
  , ""
  , unCommandSumType $ mkCommandSum tasks
  , ""
  , unDriver $ driver tasks
  ]

newtype Driver = Driver { unDriver :: String }

driver :: [Task] -> Driver
driver [] = Driver ""
driver tasks = Driver $ unlines $
    [ "kaleMain :: IO ()"
    , "kaleMain = do"
    ] ++ indent 2
    [ "cmd <- getRecord \"kale-discovery\""
    , "case (cmd :: Command) of"
    ] ++ indent 4 (map mkCaseOf tasks)

newtype CommandSumType = CommandSumType { unCommandSumType :: String }

mkCommandSum :: [Task] -> CommandSumType
mkCommandSum [] = CommandSumType ""
mkCommandSum tasks = CommandSumType $ "data Command = "
    ++ intercalate " | " (map (unTaskName . taskToSum) tasks)
    ++ " deriving (Eq, Show, Read, Generic, ParseRecord)"

taskToSum :: Task -> TaskName
taskToSum task = TaskName $ (unTaskName . taskName $ task) ++ case taskArgs task of
    NoArgs -> ""
    PositionalArgs args -> stripArgs args
    RecordArgs args -> stripArgs args

stripArgs :: String -> String
stripArgs =
    (' ' :)
    . (++ "}")
    . dropWhile (/= '{')
    . takeWhile (/= '}')

mkCaseOf :: Task -> String
mkCaseOf task = concat
    [ unTaskName . taskName $ task
    , case taskArgs task of
        NoArgs -> ""
        _ -> "{..}"
    --, maybe "" (const "{..}") (taskArgs task)
    , " -> "
    , unTaskModule . taskModule $ task
    , "Task.task"
    , case taskArgs task of
        NoArgs ->
            ""
        _ -> concat
            [ " "
            , unTaskModule . taskModule $ task
            , "Task.Args {..}"
            ]
    ]

indent :: Int -> [String] -> [String]
indent n = map (replicate n ' ' ++)

usage :: String
usage = "Kale doesn't take any arguments."

findTasks :: FilePath -> IO [Task]
findTasks src = do
  let (dir, file) = splitFileName src
  files <- filter (/= file) <$> getFilesRecursive dir
  catMaybes <$> traverse (fileToTask dir) files

fileToTask :: FilePath -> FilePath -> IO (Maybe Task)
fileToTask dir file = runMaybeT $
    case reverse $ splitDirectories file of
        [] ->
            empty
        x:xs ->  do
            name <- MaybeT . pure . stripSuffixes $ x
            guard (isValidModuleName name && all isValidModuleName xs)
            let fileName = dir </> file
            moduleContents <- liftIO $ FileContent <$> readFile fileName
            pure (mkTask moduleContents (mkTaskName name) (TaskModule $ intercalate "." (reverse (name : xs))))
  where
    stripSuffixes :: String -> Maybe String
    stripSuffixes x =
        stripSuffix "Task.hs" x <|> stripSuffix "Task.lhs" x
    stripSuffix :: Eq a => [a] -> [a] -> Maybe [a]
    stripSuffix suffix str =
        reverse <$> stripPrefix (reverse suffix) (reverse str)

newtype FileContent = FileContent { unFileContent :: String }

mkTask :: FileContent -> TaskName -> TaskModule -> Task
mkTask fileContent name mod_ = Task
    { taskModule = mod_
    , taskArgs   = mkTaskArgs fileContent
    , taskName   = name
    }

mkTaskArgs :: FileContent -> TaskArgs
mkTaskArgs fileContent = case findArgs fileContent of
  Nothing -> NoArgs
  Just args ->
    if '{' `elem` args
    then PositionalArgs args
    else RecordArgs args

mkTaskName :: String -> TaskName
mkTaskName = TaskName . casify

casify :: String -> String
casify str = intercalate "_" $ groupBy (\a b -> isUpper a && isLower b) str

findArgs :: FileContent -> Maybe String
findArgs = find ("data Args" `isPrefixOf`) . decs . unFileContent

decs :: String -> [String]
decs = reverse . fmap (collapseSpace . concat . reverse) . foldl' go [] . lines
  where
    go acc line@(c:_)
        | isSpace c || c == '}' =
            consFirst line acc
        | otherwise =
            [line] : acc
    go acc [] = acc
    consFirst a []     = [[a]]
    consFirst a (x:xs) = (a : x) : xs

collapseSpace :: String -> String
collapseSpace = unwords . words

-- See `Cabal.Distribution.ModuleName` (http://git.io/bj34)
isValidModuleName :: String -> Bool
isValidModuleName []     = False
isValidModuleName (c:cs) = isUpper c && all isValidModuleChar cs

isValidModuleChar :: Char -> Bool
isValidModuleChar c = isAlphaNum c || c == '_' || c == '\''

getFilesRecursive :: FilePath -> IO [FilePath]
getFilesRecursive baseDir = sort <$> go []
  where
    go :: FilePath -> IO [FilePath]
    go dir = do
      c <- map (dir </>) . filter (`notElem` [".", ".."]) <$> getDirectoryContents (baseDir </> dir)
      dirs <- filterM (doesDirectoryExist . (baseDir </>)) c >>= mapM go
      files <- filterM (doesFileExist . (baseDir </>)) c
      return (files ++ concat dirs)

-- | Derive module name from specified path.
pathToModule :: FilePath -> String
pathToModule f = toUpper m:ms
  where
    fileName = last $ splitDirectories f
    m:ms = takeWhile (/='.') fileName

newtype ImportList = ImportList { unImportList :: String } deriving (Show)

-- | Generate imports for a list of specs.
importList :: [Task] -> ImportList
importList = ImportList . unlines . map f
  where
    f :: Task -> String
    f task = "import qualified " ++ unTaskModule (taskModule task) ++ "Task"
