-----------------------------------------------------------------------------
-- |
-- Module      :  XMonad.Util.Run
-- Copyright   :  (C) 2007 Spencer Janssen, Andrea Rossato, glasser@mit.edu
-- License     :  BSD-style (see LICENSE)
--
-- Maintainer  :  Christian Thiemann <mail@christian-thiemann.de>
-- Stability   :  unstable
-- Portability :  unportable
--
-- This modules provides several commands to run an external process.
-- It is composed of functions formerly defined in "XMonad.Util.Dmenu" (by
-- Spencer Janssen), "XMonad.Util.Dzen" (by glasser\@mit.edu) and
-- XMonad.Util.RunInXTerm (by Andrea Rossato).
--
-----------------------------------------------------------------------------

module XMonad.Util.Run (
                          -- * Usage
                          -- $usage
                          runProcessWithInput,
                          runProcessWithInputAndWait,
                          safeSpawn,
                          safeSpawnProg,
                          unsafeSpawn,
                          runInTerm,
                          safeRunInTerm,
                          seconds,
                          spawnPipe,
                          spawnPipeWithLocaleEncoding,
                          spawnPipeWithUtf8Encoding,
                          hPutStr, hPutStrLn  -- re-export for convenience
                         ) where

import Codec.Binary.UTF8.String
import System.Posix.IO
import System.Posix.Process (createSession, executeFile, forkProcess)
import Control.Concurrent (threadDelay)
import System.IO
import System.Process (runInteractiveProcess)
import XMonad
import Control.Monad
import qualified GHC.IO.FD as FD
import qualified GHC.IO.Handle.FD as FD
import qualified System.Posix.Internals as Posix

-- $usage
-- For an example usage of 'runInTerm' see "XMonad.Prompt.Ssh"
--
-- For an example usage of 'runProcessWithInput' see
-- "XMonad.Prompt.DirectoryPrompt", "XMonad.Util.Dmenu",
-- "XMonad.Prompt.ShellPrompt", "XMonad.Actions.WmiiActions",
-- "XMonad.Prompt.WorkspaceDir"
--
-- For an example usage of 'runProcessWithInputAndWait' see
-- "XMonad.Util.Dzen"

-- | Returns the output.
runProcessWithInput :: MonadIO m => FilePath -> [String] -> String -> m String
runProcessWithInput cmd args input = io $ do
    (pin, pout, perr, _) <- runInteractiveProcess (encodeString cmd)
                                            (map encodeString args) Nothing Nothing
    hPutStr pin input
    hClose pin
    output <- hGetContents pout
    when (output == output) $ return ()
    hClose pout
    hClose perr
    -- no need to waitForProcess, we ignore SIGCHLD
    return output

-- | Wait is in &#956; (microseconds)
runProcessWithInputAndWait :: MonadIO m => FilePath -> [String] -> String -> Int -> m ()
runProcessWithInputAndWait cmd args input timeout = io $ do
    _ <- xfork $ do
        (pin, pout, perr, _) <- runInteractiveProcess (encodeString cmd)
                                            (map encodeString args) Nothing Nothing
        hPutStr pin input
        hFlush pin
        threadDelay timeout
        hClose pin
        hClose pout
        hClose perr
        -- no need to waitForProcess, we ignore SIGCHLD
        return ()
    return ()

-- | Multiplies by ONE MILLION, for functions that take microseconds.
--
-- Use like:
--
-- > (5.5 `seconds`)
--
-- In GHC 7 and later, you must either enable the PostfixOperators extension
-- (by adding
--
-- > {-# LANGUAGE PostfixOperators #-}
--
-- to the top of your file) or use seconds in prefix form:
--
-- > seconds 5.5
seconds :: Rational -> Int
seconds = fromEnum . (* 1000000)

{- | 'safeSpawn' bypasses 'spawn', because spawn passes
strings to \/bin\/sh to be interpreted as shell commands. This is
often what one wants, but in many cases the passed string will contain
shell metacharacters which one does not want interpreted as such (URLs
particularly often have shell metacharacters like \'&\' in them). In
this case, it is more useful to specify a file or program to be run
and a string to give it as an argument so as to bypass the shell and
be certain the program will receive the string as you typed it.

Examples:

> , ((modm, xK_Print), unsafeSpawn "import -window root $HOME/xwd-$(date +%s)$$.png")
> , ((modm, xK_d    ), safeSpawn "firefox" [])

Note that the unsafeSpawn example must be unsafe and not safe because
it makes use of shell interpretation by relying on @$HOME@ and
interpolation, whereas the safeSpawn example can be safe because
Firefox doesn't need any arguments if it is just being started. -}
safeSpawn :: MonadIO m => FilePath -> [String] -> m ()
safeSpawn prog args = io $ void_ $ forkProcess $ do
  uninstallSignalHandlers
  _ <- createSession
  executeFile (encodeString prog) True (map encodeString args) Nothing
    where void_ = (>> return ()) -- TODO: replace with Control.Monad.void / void not in ghc6 apparently

-- | Simplified 'safeSpawn'; only takes a program (and no arguments):
--
-- > , ((modm, xK_d    ), safeSpawnProg "firefox")
safeSpawnProg :: MonadIO m => FilePath -> m ()
safeSpawnProg = flip safeSpawn []

-- | An alias for 'spawn'; the name emphasizes that one is calling out to a
--   Turing-complete interpreter which may do things one dislikes; for details, see 'safeSpawn'.
unsafeSpawn :: MonadIO m => String -> m ()
unsafeSpawn = spawn

-- | Open a terminal emulator. The terminal emulator is specified in the default configuration as xterm by default. It is then
-- asked to pass the shell a command with certain options. This is unsafe in the sense of 'unsafeSpawn'
unsafeRunInTerm, runInTerm :: String -> String -> X ()
unsafeRunInTerm options command = asks (terminal . config) >>= \t -> unsafeSpawn $ t ++ " " ++ options ++ " -e " ++ command
runInTerm = unsafeRunInTerm

-- | Run a given program in the preferred terminal emulator; see 'runInTerm'. This makes use of 'safeSpawn'.
safeRunInTerm :: String -> String -> X ()
safeRunInTerm options command = asks (terminal . config) >>= \t -> safeSpawn t [options, " -e " ++ command]

-- | Launch an external application through the system shell and
-- return a @Handle@ to its standard input. Note that the @Handle@
-- is a binary Handle. You should probably use 'spawnPipeWithUtf8Encoding'.
spawnPipe :: MonadIO m => String -> m Handle
spawnPipe x = io $ do
    (rd, wr) <- createPipe
    setFdOption wr CloseOnExec True
    h <- fdToHandle wr
    hSetBuffering h LineBuffering
    _ <- xfork $ do
          _ <- dupTo rd stdInput
          executeFile "/bin/sh" False ["-c", encodeString x] Nothing
    closeFd rd
    return h

-- | Same as 'spawnPipe', but uses the current 'localeEncoding'.
spawnPipeWithLocaleEncoding :: MonadIO m => String -> m Handle
spawnPipeWithLocaleEncoding x = io $ do
    (rd, wr) <- createPipe
    setFdOption wr CloseOnExec True
    h <- fdToTextHandle (fromIntegral wr) localeEncoding
    hSetBuffering h LineBuffering
    _ <- xfork $ do
          _ <- dupTo rd stdInput
          executeFile "/bin/sh" False ["-c", encodeString x] Nothing
    closeFd rd
    return h

-- | Same as 'spawnPipe', but uses the 'utf8' encoding.
spawnPipeWithUtf8Encoding :: MonadIO m => String -> m Handle
spawnPipeWithUtf8Encoding x = io $ do
    (rd, wr) <- createPipe
    setFdOption wr CloseOnExec True
    h <- fdToTextHandle (fromIntegral wr) utf8
    hSetBuffering h LineBuffering
    _ <- xfork $ do
          _ <- dupTo rd stdInput
          executeFile "/bin/sh" False ["-c", encodeString x] Nothing
    closeFd rd
    return h

-- | Same as 'fdToHandle', but this makes a text Handle instead of
-- Binary. The handle is set with the 'TextEncoding' you pass.
--
-- Implementation taken and modified from <https://www.stackage.org/haddock/lts-15.9/base-4.13.0.0/src/GHC-IO-Handle-FD.html#fdToHandle>
fdToTextHandle :: Posix.FD -> TextEncoding -> IO Handle
fdToTextHandle fdint encoding = do
   iomode <- Posix.fdGetMode fdint
   (fd,fd_type) <- FD.mkFD fdint iomode Nothing
            False{-is_socket-} 
              -- NB. the is_socket flag is False, meaning that:
              --  on Windows we're guessing this is not a socket (XXX)
            False{-is_nonblock-}
              -- file descriptors that we get from external sources are
              -- not put into non-blocking mode, because that would affect
              -- other users of the file descriptor
   let fd_str = "<file descriptor: " ++ show fd ++ ">"
   FD.mkHandleFromFD fd fd_type fd_str iomode False{-non-block-} 
                     (Just encoding)

