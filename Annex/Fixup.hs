{- git-annex repository fixups
 -
 - Copyright 2013, 2015 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Annex.Fixup where

import Git.Types
import Git.Config
import Types.GitConfig
import qualified Git.Construct as Construct
import Utility.Path
import Utility.SafeCommand
import Utility.Directory
import Utility.PosixFiles
import Utility.Exception

import System.IO
import System.FilePath
import System.Directory
import Data.List
import Control.Monad
import Control.Monad.IfElse
import qualified Data.Map as M

fixupRepo :: Repo -> GitConfig -> IO Repo
fixupRepo r c = do
	r' <- fixupSubmodule r c
	if annexDirect c
		then fixupDirect r'
		else return r'

{- Direct mode repos have core.bare=true, but are not really bare.
 - Fix up the Repo to be a non-bare repo, and arrange for git commands
 - run by git-annex to be passed parameters that override this setting. -}
fixupDirect :: Repo -> IO Repo
fixupDirect r@(Repo { location = l@(Local { gitdir = d, worktree = Nothing }) }) = do
	let r' = r
		{ location = l { worktree = Just (parentDir d) }
		, gitGlobalOpts = gitGlobalOpts r ++
			[ Param "-c"
			, Param $ coreBare ++ "=" ++ boolConfig False
			]
		}
	-- Recalc now that the worktree is correct.
	rs' <- Construct.fromRemotes r'
	return $ r' { remotes = rs' }
fixupDirect r = return r

{- Submodules have their gitdir containing ".git/modules/", and
 - have core.worktree set, and also have a .git file in the top
 - of the repo. 
 -
 - We need to unset core.worktree, and change the .git file into a
 - symlink to the git directory. This way, annex symlinks will be
 - of the usual .git/annex/object form, and will consistently work
 - whether a repo is used as a submodule or not, and wheverever the
 - submodule is mounted.
 -
 - When the filesystem doesn't support symlinks, we cannot make .git
 - into a symlink. In this case, we merely adjust the Repo so that
 - symlinks to objects that get checked in will be in the right form.
 -}
fixupSubmodule :: Repo -> GitConfig -> IO Repo
fixupSubmodule r@(Repo { location = l@(Local { worktree = Just w, gitdir = d }) }) c
	| (".git" </> "modules") `isInfixOf` d = do
		when (coreSymlinks c) $
			replacedotgit
				`catchNonAsync` \_e -> hPutStrLn stderr
					"warning: unable to convert submodule to form that will work with git-annex"
		return $ r
			{ location = if coreSymlinks c
				then l { gitdir = dotgit }
				else l
			, config = M.delete "core.worktree" (config r)
			}
  where
	dotgit = w </> ".git"
	replacedotgit = whenM (doesFileExist dotgit) $ do
		nukeFile dotgit
		createSymbolicLink (w </> d) dotgit
		maybe (error "unset core.worktree failed") (\_ -> return ())
			=<< Git.Config.unset "core.worktree" r
fixupSubmodule r _ = return r
