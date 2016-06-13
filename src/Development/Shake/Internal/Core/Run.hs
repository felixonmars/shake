{-# LANGUAGE RecordWildCards, GeneralizedNewtypeDeriving, ScopedTypeVariables, PatternGuards #-}
{-# LANGUAGE ExistentialQuantification, MultiParamTypeClasses, ConstraintKinds #-}

module Development.Shake.Internal.Core.Run(
    run,
    Action, actionOnException, actionFinally, apply, apply1, traced, getShakeOptions, getProgress,
    trackUse, trackChange, trackAllow,
    getVerbosity, putLoud, putNormal, putQuiet, withVerbosity, quietly,
    Resource, newResource, newResourceIO, withResource, withResources, newThrottle, newThrottleIO,
    newCache, newCacheIO,
    unsafeExtraThread, unsafeAllowApply,
    parallel,
    orderOnlyAction,
    -- Internal stuff
    runAfter
    ) where

import Control.Exception.Extra
import Control.Applicative
import Data.Tuple.Extra
import Control.Concurrent.Extra
import Control.Monad.Extra
import Control.Monad.IO.Class
import Data.Typeable
import Data.Function
import Data.Either.Extra
import Data.List.Extra
import qualified Data.HashMap.Strict as Map
import Data.Maybe
import Data.IORef
import System.Directory
import System.IO.Extra
import System.Time.Extra

import Development.Shake.Classes
import Development.Shake.Internal.Core.Action
import Development.Shake.Internal.Core.Rules
import Development.Shake.Internal.Core.Pool
import Development.Shake.Internal.Core.Database
import Development.Shake.Internal.Core.Monad
import Development.Shake.Internal.Resource
import Development.Shake.Internal.Value
import Development.Shake.Internal.Profile
import Development.Shake.Internal.Types
import Development.Shake.Internal.Errors
import Development.Shake.Internal.Special
import General.Timing
import General.Extra
import General.Concurrent
import General.Cleanup
import Prelude

---------------------------------------------------------------------
-- MAKE

-- | Internal main function (not exported publicly)
run :: ShakeOptions -> Rules () -> IO ()
run opts@ShakeOptions{..} rs = (if shakeLineBuffering then lineBuffering else id) $ do
    opts@ShakeOptions{..} <- if shakeThreads /= 0 then return opts else do p <- getProcessorCount; return opts{shakeThreads=p}

    start <- offsetTime
    (actions, ruleinfo) <- runRules opts rs

    outputLocked <- do
        lock <- newLock
        return $ \v msg -> withLock lock $ shakeOutput v msg

    let diagnostic = if shakeVerbosity >= Diagnostic then outputLocked Diagnostic . ("% "++) else const $ return ()
    let output v = outputLocked v . abbreviate shakeAbbreviations
    diagnostic "Starting run"

    except <- newIORef (Nothing :: Maybe (String, ShakeException))
    let raiseError err
            | not shakeStaunch = throwIO err
            | otherwise = do
                let named = abbreviate shakeAbbreviations . shakeExceptionTarget
                atomicModifyIORef except $ \v -> (Just $ fromMaybe (named err, err) v, ())
                -- no need to print exceptions here, they get printed when they are wrapped

    lint <- if isNothing shakeLint then return $ const $ return () else do
        dir <- getCurrentDirectory
        return $ \msg -> do
            now <- getCurrentDirectory
            when (dir /= now) $ errorStructured
                "Lint checking error - current directory has changed"
                [("When", Just msg)
                ,("Wanted",Just dir)
                ,("Got",Just now)]
                ""
    diagnostic "Starting run 2"

    after <- newIORef []
    absent <- newIORef []
    withCleanup $ \cleanup -> do
        _ <- addCleanup cleanup $ do
            when shakeTimings printTimings
            resetTimings -- so we don't leak memory
        withNumCapabilities shakeThreads $ do
            diagnostic "Starting run 3"
            withDatabase opts diagnostic $ \database -> do
                wait <- newBarrier
                let getProgress = do
                        failure <- fmap fst <$> readIORef except
                        stats <- progress database
                        return stats{isFailure=failure}
                tid <- flip forkFinally (const $ signalBarrier wait ()) $
                    shakeProgress getProgress
                _ <- addCleanup cleanup $ do
                    killThread tid
                    void $ timeout 1000000 $ waitBarrier wait

                addTiming "Running rules"
                runPool (shakeThreads == 1) shakeThreads $ \pool -> do
                    let s0 = Global database pool cleanup start ruleinfo output opts diagnostic lint after absent getProgress
                    let s1 = newLocal emptyStack shakeVerbosity
                    forM_ actions $ \act ->
                        addPool pool $ runAction s0 s1 act $ \x -> case x of
                            Left e -> raiseError =<< shakeException s0 (return ["Top-level action/want"]) e
                            Right x -> return x
                maybe (return ()) (throwIO . snd) =<< readIORef except
                assertFinishedDatabase database

                when (null actions) $
                    when (shakeVerbosity >= Normal) $ output Normal "Warning: No want/action statements, nothing to do"

                when (isJust shakeLint) $ do
                    addTiming "Lint checking"
                    absent <- readIORef absent
                    checkValid database (runStored ruleinfo) (runEqual ruleinfo) absent
                    when (shakeVerbosity >= Loud) $ output Loud "Lint checking succeeded"
                when (shakeReport /= []) $ do
                    addTiming "Profile report"
                    report <- toReport database
                    forM_ shakeReport $ \file -> do
                        when (shakeVerbosity >= Normal) $
                            output Normal $ "Writing report to " ++ file
                        writeProfile file report
                when (shakeLiveFiles /= []) $ do
                    addTiming "Listing live"
                    live <- listLive database
                    let liveFiles = [show k | k <- live, specialIsFileKey $ typeKey k]
                    forM_ shakeLiveFiles $ \file -> do
                        when (shakeVerbosity >= Normal) $
                            output Normal $ "Writing live list to " ++ file
                        (if file == "-" then putStr else writeFile file) $ unlines liveFiles
            sequence_ . reverse =<< readIORef after


lineBuffering :: IO a -> IO a
lineBuffering = withBuffering stdout LineBuffering . withBuffering stderr LineBuffering


abbreviate :: [(String,String)] -> String -> String
abbreviate [] = id
abbreviate abbrev = f
    where
        -- order so longer abbreviations are preferred
        ordAbbrev = sortOn (negate . length . fst) abbrev

        f [] = []
        f x | (to,rest):_ <- [(to,rest) | (from,to) <- ordAbbrev, Just rest <- [stripPrefix from x]] = to ++ f rest
        f (x:xs) = x : f xs


-- | Execute a rule, returning the associated values. If possible, the rules will be run in parallel.
--   This function requires that appropriate rules have been added with 'rule'.
--   All @key@ values passed to 'apply' become dependencies of the 'Action'.
apply :: Rule key value => [key] -> Action [value]
apply = applyForall

-- We don't want the forall in the Haddock docs
-- Don't short-circuit [] as we still want error messages
applyForall :: forall key value . Rule key value => [key] -> Action [value]
applyForall ks = do
    let tk = typeOf (err "apply key" :: key)
        tv = typeOf (err "apply type" :: value)
    Global{..} <- Action getRO
    block <- Action $ getsRW localBlockApply
    whenJust block $ liftIO . errorNoApply tk (show <$> listToMaybe ks)
    case Map.lookup tk globalRules of
        Nothing -> liftIO $ errorNoRuleToBuildType tk (show <$> listToMaybe ks) (Just tv)
        Just RuleInfo{resultType=tv2} | tv /= tv2 -> liftIO $ errorRuleTypeMismatch tk (show <$> listToMaybe ks) tv2 tv
        _ -> fmap (map fromValue) $ applyKeyValue $ map newKey ks


applyKeyValue :: [Key] -> Action [Value]
applyKeyValue [] = return []
applyKeyValue ks = do
    global@Global{..} <- Action getRO
    let exec stack k continue = do
            let s = newLocal stack (shakeVerbosity globalOptions)
            let top = showTopStack stack
            time <- offsetTime
            runAction global s (do
                liftIO $ evaluate $ rnf k
                liftIO $ globalLint $ "before building " ++ top
                putWhen Chatty $ "# " ++ show k
                res <- runExecute globalRules k
                when (Just LintFSATrace == shakeLint globalOptions) trackCheckUsed
                Action $ fmap ((,) res) getRW) $ \x -> case x of
                    Left e -> continue . Left . toException =<< shakeException global (showStack globalDatabase stack) e
                    Right (res, Local{..}) -> do
                        dur <- time
                        globalLint $ "after building " ++ top
                        let ans = (res, reverse localDepends, dur - localDiscount, reverse localTraces)
                        evaluate $ rnf ans
                        continue $ Right ans
    stack <- Action $ getsRW localStack
    (dur, dep, vs) <- Action $ captureRAW $ build globalPool globalDatabase (Ops (runStored globalRules) (runEqual globalRules) exec) stack ks
    Action $ modifyRW $ \s -> s{localDiscount=localDiscount s + dur, localDepends=dep : localDepends s}
    return vs



runStored :: Map.HashMap TypeRep RuleInfo -> Key -> IO (Maybe Value)
runStored mp k = case Map.lookup (typeKey k) mp of
    Nothing -> return Nothing
    Just RuleInfo{..} -> stored k

runEqual :: Map.HashMap TypeRep RuleInfo -> Key -> Value -> Value -> EqualCost
runEqual mp k v1 v2 = case Map.lookup (typeKey k) mp of
    Nothing -> NotEqual
    Just RuleInfo{..} -> equal k v1 v2

runExecute :: Map.HashMap TypeRep RuleInfo -> Key -> Action Value
runExecute mp k = let tk = typeKey k in case Map.lookup tk mp of
    Nothing -> liftIO $ errorNoRuleToBuildType tk (Just $ show k) Nothing
    Just RuleInfo{..} -> execute k


-- | Turn a normal exception into a ShakeException, giving it a stack and printing it out if in staunch mode.
--   If the exception is already a ShakeException (e.g. it's a child of ours who failed and we are rethrowing)
--   then do nothing with it.
shakeException :: Global -> IO [String] -> SomeException -> IO ShakeException
shakeException Global{globalOptions=ShakeOptions{..},..} stk e@(SomeException inner) = case cast inner of
    Just e@ShakeException{} -> return e
    Nothing -> do
        stk <- stk
        e <- return $ ShakeException (last $ "Unknown call stack" : stk) stk e
        when (shakeStaunch && shakeVerbosity >= Quiet) $
            globalOutput Quiet $ show e ++ "Continuing due to staunch mode"
        return e


-- | Apply a single rule, equivalent to calling 'apply' with a singleton list. Where possible,
--   use 'apply' to allow parallelism.
apply1 :: Rule key value => key -> Action value
apply1 = fmap head . apply . return


---------------------------------------------------------------------
-- TRACKING

-- | Track that a key has been used by the action preceeding it.
trackUse :: ShakeValue key => key -> Action ()
-- One of the following must be true:
-- 1) you are the one building this key (e.g. key == topStack)
-- 2) you have already been used by apply, and are on the dependency list
-- 3) someone explicitly gave you permission with trackAllow
-- 4) at the end of the rule, a) you are now on the dependency list, and b) this key itself has no dependencies (is source file)
trackUse key = do
    let k = newKey key
    Global{..} <- Action getRO
    l@Local{..} <- Action getRW
    deps <- liftIO $ concatMapM (listDepends globalDatabase) localDepends
    let top = topStack localStack
    if top == Just k then
        return () -- condition 1
     else if k `elem` deps then
        return () -- condition 2
     else if any ($ k) localTrackAllows then
        return () -- condition 3
     else
        Action $ putRW l{localTrackUsed = k : localTrackUsed} -- condition 4


trackCheckUsed :: Action ()
trackCheckUsed = do
    Global{..} <- Action getRO
    Local{..} <- Action getRW
    liftIO $ do
        deps <- concatMapM (listDepends globalDatabase) localDepends

        -- check 3a
        bad <- return $ localTrackUsed \\ deps
        unless (null bad) $ do
            let n = length bad
            errorStructured
                ("Lint checking error - " ++ (if n == 1 then "value was" else show n ++ " values were") ++ " used but not depended upon")
                [("Used", Just $ show x) | x <- bad]
                ""

        -- check 3b
        bad <- flip filterM localTrackUsed $ \k -> (not . null) <$> lookupDependencies globalDatabase k
        unless (null bad) $ do
            let n = length bad
            errorStructured
                ("Lint checking error - " ++ (if n == 1 then "value was" else show n ++ " values were") ++ " depended upon after being used")
                [("Used", Just $ show x) | x <- bad]
                ""


-- | Track that a key has been changed by the action preceeding it.
trackChange :: ShakeValue key => key -> Action ()
-- One of the following must be true:
-- 1) you are the one building this key (e.g. key == topStack)
-- 2) someone explicitly gave you permission with trackAllow
-- 3) this file is never known to the build system, at the end it is not in the database
trackChange key = do
    let k = newKey key
    Global{..} <- Action getRO
    Local{..} <- Action getRW
    liftIO $ do
        let top = topStack localStack
        if top == Just k then
            return () -- condition 1
         else if any ($ k) localTrackAllows then
            return () -- condition 2
         else
            -- condition 3
            atomicModifyIORef globalTrackAbsent $ \ks -> ((fromMaybe k top, k):ks, ())


-- | Allow any matching key to violate the tracking rules.
trackAllow :: ShakeValue key => (key -> Bool) -> Action ()
trackAllow = trackAllowForall

-- We don't want the forall in the Haddock docs
trackAllowForall :: forall key . ShakeValue key => (key -> Bool) -> Action ()
trackAllowForall test = Action $ modifyRW $ \s -> s{localTrackAllows = f : localTrackAllows s}
    where
        tk = typeOf (err "trackAllow key" :: key)
        f k = typeKey k == tk && test (fromKey k)


---------------------------------------------------------------------
-- RESOURCES

-- | Create a finite resource, given a name (for error messages) and a quantity of the resource that exists.
--   Shake will ensure that actions using the same finite resource do not execute in parallel.
--   As an example, only one set of calls to the Excel API can occur at one time, therefore
--   Excel is a finite resource of quantity 1. You can write:
--
-- @
-- 'Development.Shake.shake' 'Development.Shake.shakeOptions'{'Development.Shake.shakeThreads'=2} $ do
--    'Development.Shake.want' [\"a.xls\",\"b.xls\"]
--    excel <- 'Development.Shake.newResource' \"Excel\" 1
--    \"*.xls\" 'Development.Shake.%>' \\out ->
--        'Development.Shake.withResource' excel 1 $
--            'Development.Shake.cmd' \"excel\" out ...
-- @
--
--   Now the two calls to @excel@ will not happen in parallel.
--
--   As another example, calls to compilers are usually CPU bound but calls to linkers are usually
--   disk bound. Running 8 linkers will often cause an 8 CPU system to grid to a halt. We can limit
--   ourselves to 4 linkers with:
--
-- @
-- disk <- 'Development.Shake.newResource' \"Disk\" 4
-- 'Development.Shake.want' [show i 'Development.Shake.FilePath.<.>' \"exe\" | i <- [1..100]]
-- \"*.exe\" 'Development.Shake.%>' \\out ->
--     'Development.Shake.withResource' disk 1 $
--         'Development.Shake.cmd' \"ld -o\" [out] ...
-- \"*.o\" 'Development.Shake.%>' \\out ->
--     'Development.Shake.cmd' \"cl -o\" [out] ...
-- @
newResource :: String -> Int -> Rules Resource
newResource name mx = liftIO $ newResourceIO name mx


-- | Create a throttled resource, given a name (for error messages) and a number of resources (the 'Int') that can be
--   used per time period (the 'Double' in seconds). Shake will ensure that actions using the same throttled resource
--   do not exceed the limits. As an example, let us assume that making more than 1 request every 5 seconds to
--   Google results in our client being blacklisted, we can write:
--
-- @
-- google <- 'Development.Shake.newThrottle' \"Google\" 1 5
-- \"*.url\" 'Development.Shake.%>' \\out -> do
--     'Development.Shake.withResource' google 1 $
--         'Development.Shake.cmd' \"wget\" [\"http:\/\/google.com?q=\" ++ 'Development.Shake.FilePath.takeBaseName' out] \"-O\" [out]
-- @
--
--   Now we will wait at least 5 seconds after querying Google before performing another query. If Google change the rules to
--   allow 12 requests per minute we can instead use @'Development.Shake.newThrottle' \"Google\" 12 60@, which would allow
--   greater parallelisation, and avoid throttling entirely if only a small number of requests are necessary.
--
--   In the original example we never make a fresh request until 5 seconds after the previous request has /completed/. If we instead
--   want to throttle requests since the previous request /started/ we can write:
--
-- @
-- google <- 'Development.Shake.newThrottle' \"Google\" 1 5
-- \"*.url\" 'Development.Shake.%>' \\out -> do
--     'Development.Shake.withResource' google 1 $ return ()
--     'Development.Shake.cmd' \"wget\" [\"http:\/\/google.com?q=\" ++ 'Development.Shake.FilePath.takeBaseName' out] \"-O\" [out]
-- @
--
--   However, the rule may not continue running immediately after 'Development.Shake.withResource' completes, so while
--   we will never exceed an average of 1 request every 5 seconds, we may end up running an unbounded number of
--   requests simultaneously. If this limitation causes a problem in practice it can be fixed.
newThrottle :: String -> Int -> Double -> Rules Resource
newThrottle name count period = liftIO $ newThrottleIO name count period


-- | Run an action which uses part of a finite resource. For more details see 'Resource'.
--   You cannot depend on a rule (e.g. 'need') while a resource is held.
withResource :: Resource -> Int -> Action a -> Action a
withResource r i act = do
    Global{..} <- Action getRO
    liftIO $ globalDiagnostic $ show r ++ " waiting to acquire " ++ show i
    offset <- liftIO offsetTime
    Action $ captureRAW $ \continue -> acquireResource r globalPool i $ continue $ Right ()
    res <- Action $ tryRAW $ fromAction $ blockApply ("Within withResource using " ++ show r) $ do
        offset <- liftIO offset
        liftIO $ globalDiagnostic $ show r ++ " acquired " ++ show i ++ " in " ++ showDuration offset
        Action $ modifyRW $ \s -> s{localDiscount = localDiscount s + offset}
        act
    liftIO $ releaseResource r globalPool i
    liftIO $ globalDiagnostic $ show r ++ " released " ++ show i
    Action $ either throwRAW return res


-- | Run an action which uses part of several finite resources. Acquires the resources in a stable
--   order, to prevent deadlock. If all rules requiring more than one resource acquire those
--   resources with a single call to 'withResources', resources will not deadlock.
withResources :: [(Resource, Int)] -> Action a -> Action a
withResources res act
    | (r,i):_ <- filter ((< 0) . snd) res = error $ "You cannot acquire a negative quantity of " ++ show r ++ ", requested " ++ show i
    | otherwise = f $ groupBy ((==) `on` fst) $ sortBy (compare `on` fst) res
    where
        f [] = act
        f (r:rs) = withResource (fst $ head r) (sum $ map snd r) $ f rs


-- | A version of 'newCache' that runs in IO, and can be called before calling 'Development.Shake.shake'.
--   Most people should use 'newCache' instead.
newCacheIO :: (Eq k, Hashable k) => (k -> Action v) -> IO (k -> Action v)
newCacheIO act = do
    var {- :: Var (Map k (Fence (Either SomeException ([Depends],v)))) -} <- newVar Map.empty
    return $ \key ->
        join $ liftIO $ modifyVar var $ \mp -> case Map.lookup key mp of
            Just bar -> return $ (,) mp $ do
                res <- liftIO $ testFence bar
                (res,offset) <- case res of
                    Just res -> return (res, 0)
                    Nothing -> do
                        pool <- Action $ getsRO globalPool
                        offset <- liftIO offsetTime
                        Action $ captureRAW $ \k -> waitFence bar $ \v ->
                            addPool pool $ do offset <- liftIO offset; k $ Right (v,offset)
                case res of
                    Left err -> Action $ throwRAW err
                    Right (deps,v) -> do
                        Action $ modifyRW $ \s -> s{localDepends = deps ++ localDepends s, localDiscount = localDiscount s + offset}
                        return v
            Nothing -> do
                bar <- newFence
                return $ (,) (Map.insert key bar mp) $ do
                    pre <- Action $ getsRW localDepends
                    res <- Action $ tryRAW $ fromAction $ act key
                    case res of
                        Left err -> do
                            liftIO $ signalFence bar $ Left err
                            Action $ throwRAW err
                        Right v -> do
                            post <- Action $ getsRW localDepends
                            let deps = take (length post - length pre) post
                            liftIO $ signalFence bar $ Right (deps, v)
                            return v

-- | Given an action on a key, produce a cached version that will execute the action at most once per key.
--   Using the cached result will still result include any dependencies that the action requires.
--   Each call to 'newCache' creates a separate cache that is independent of all other calls to 'newCache'.
--
--   This function is useful when creating files that store intermediate values,
--   to avoid the overhead of repeatedly reading from disk, particularly if the file requires expensive parsing.
--   As an example:
--
-- @
-- digits \<- 'newCache' $ \\file -> do
--     src \<- readFile\' file
--     return $ length $ filter isDigit src
-- \"*.digits\" 'Development.Shake.%>' \\x -> do
--     v1 \<- digits ('dropExtension' x)
--     v2 \<- digits ('dropExtension' x)
--     'Development.Shake.writeFile'' x $ show (v1,v2)
-- @
--
--   To create the result @MyFile.txt.digits@ the file @MyFile.txt@ will be read and counted, but only at most
--   once per execution.
newCache :: (Eq k, Hashable k) => (k -> Action v) -> Rules (k -> Action v)
newCache = liftIO . newCacheIO


-- | Run an action without counting to the thread limit, typically used for actions that execute
--   on remote machines using barely any local CPU resources.
--   Unsafe as it allows the 'shakeThreads' limit to be exceeded.
--   You cannot depend on a rule (e.g. 'need') while the extra thread is executing.
--   If the rule blocks (e.g. calls 'withResource') then the extra thread may be used by some other action.
--   Only really suitable for calling 'cmd'/'command'.
unsafeExtraThread :: Action a -> Action a
unsafeExtraThread act = Action $ do
    Global{..} <- getRO
    stop <- liftIO $ increasePool globalPool
    res <- tryRAW $ fromAction $ blockApply "Within unsafeExtraThread" act
    liftIO stop
    captureRAW $ \continue -> (if isLeft res then addPoolPriority else addPool) globalPool $ continue res


-- | Execute a list of actions in parallel. In most cases 'need' will be more appropriate to benefit from parallelism.
parallel :: [Action a] -> Action [a]
parallel [] = return []
parallel [x] = fmap return x
parallel acts = Action $ do
    global@Global{..} <- getRO
    local <- getRW
    -- number of items still to complete, or Nothing for has completed (by either failure or completion)
    todo :: Var (Maybe Int) <- liftIO $ newVar $ Just $ length acts
    -- a list of refs where the results go
    results :: [IORef (Maybe (Either SomeException a))] <- liftIO $ replicateM (length acts) $ newIORef Nothing

    captureRAW $ \continue -> do
        let resume = do
                res <- liftIO $ sequence . catMaybes <$> mapM readIORef results
                continue res

        liftIO $ forM_ (zip acts results) $ \(act, result) -> do
            let act2 = ifM (liftIO $ isJust <$> readVar todo) act (fail "")
            addPool globalPool $ runAction global local act2 $ \res -> do
                writeIORef result $ Just res
                modifyVar_ todo $ \v -> case v of
                    Nothing -> return Nothing
                    Just i | i == 1 || isLeft res -> do resume; return Nothing
                    Just i -> return $ Just $ i - 1


-- | Run an action but do not depend on anything the action uses.
--   A more general version of 'orderOnly'.
orderOnlyAction :: Action a -> Action a
orderOnlyAction act = Action $ do
    pre <- getsRW localDepends
    res <- fromAction act
    modifyRW $ \s -> s{localDepends=pre}
    return res
