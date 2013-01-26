{- git-annex file permissions
 -
 - Copyright 2012 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Annex.Perms (
	setAnnexPerm,
	annexFileMode,
	createAnnexDirectory,
	noUmask,
	createContentDir,
	freezeContentDir,
) where

import Common.Annex
import Utility.FileMode
import Git.SharedRepository
import qualified Annex

import System.Posix.Types

withShared :: (SharedRepository -> Annex a) -> Annex a
withShared a = maybe startup a =<< Annex.getState Annex.shared
  where
	startup = do
		shared <- fromRepo getSharedRepository
		Annex.changeState $ \s -> s { Annex.shared = Just shared }
		a shared

{- Sets appropriate file mode for a file or directory in the annex,
 - other than the content files and content directory. Normally,
 - use the default mode, but with core.sharedRepository set,
 - allow the group to write, etc. -}
setAnnexPerm :: FilePath -> Annex ()
setAnnexPerm file = withShared $ liftIO . go
  where
	go GroupShared = groupWriteRead file
	go AllShared = modifyFileMode file $ addModes $
		[ ownerWriteMode, groupWriteMode ] ++ readModes
	go _ = noop

{- Gets the appropriate mode to use for creating a file in the annex
 - (other than content files, which are locked down more). -}
annexFileMode :: Annex FileMode
annexFileMode = withShared $ return . go
  where
	go GroupShared = sharedmode
	go AllShared = combineModes (sharedmode:readModes)
	go _ = stdFileMode
	sharedmode = combineModes
		[ ownerWriteMode, groupWriteMode
		, ownerReadMode, groupReadMode
		]

{- Creates a directory inside the gitAnnexDir, including any parent
 - directories. Makes directories with appropriate permissions. -}
createAnnexDirectory :: FilePath -> Annex ()
createAnnexDirectory dir = traverse dir [] =<< top
  where
	top = parentDir <$> fromRepo gitAnnexDir
	traverse d below stop
		| d `equalFilePath` stop = done
		| otherwise = ifM (liftIO $ doesDirectoryExist d)
			( done
			, traverse (parentDir d) (d:below) stop
			)
	  where
		done = forM_ below $ \p -> do
			liftIO $ createDirectory p
			setAnnexPerm p

{- Blocks writing to the directory an annexed file is in, to prevent the
 - file accidentially being deleted. However, if core.sharedRepository
 - is set, this is not done, since the group must be allowed to delete the
 - file.
 -}
freezeContentDir :: FilePath -> Annex ()
freezeContentDir file = liftIO . go =<< fromRepo getSharedRepository
  where
	dir = parentDir file
	go GroupShared = groupWriteRead dir
	go AllShared = groupWriteRead dir
	go _ = preventWrite dir

{- Makes the directory tree to store an annexed file's content,
 - with appropriate permissions on each level. -}
createContentDir :: FilePath -> Annex ()
createContentDir dest = do
	unlessM (liftIO $ doesDirectoryExist dir) $
		createAnnexDirectory dir 
	-- might have already existed with restricted perms
	liftIO $ allowWrite dir
  where
	dir = parentDir dest
