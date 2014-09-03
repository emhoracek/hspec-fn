{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE TupleSections        #-}
{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE TypeSynonymInstances #-}

module Test.Hspec.Snap where

import           Control.Applicative     ((<$>))
import           Control.Concurrent.MVar
import           Control.Exception       (SomeException, catch)
import           Control.Monad.State     (StateT (..), runStateT)
import qualified Control.Monad.State     as S (get, put)
import           Control.Monad.Trans     (liftIO)
import qualified Data.Map                as M
import           Data.Maybe              (fromMaybe)
import           Data.Text               (Text)
import qualified Data.Text               as T
import qualified Data.Text.Encoding      as T
import           Snap
import           Snap.Core               (Response (..), getHeader)
import           Snap.Snaplet            (Handler, Snaplet, SnapletInit)
import           Snap.Snaplet.Test       (InitializerState, closeSnaplet,
                                          evalHandler', getSnaplet, runHandler')
import           Snap.Test               (RequestBuilder, getResponseBody)
import qualified Snap.Test               as Test
import           Test.Hspec
import           Test.Hspec.Core
import qualified Text.HandsomeSoup       as HS
import qualified Text.XML.HXT.Core       as HXT

data TestResponse = Html Text | NotFound | Redirect Int Text | Other Int | Empty deriving (Show, Eq)

data SnapState b = SnapState Result (Handler b b ()) (Snaplet b) (InitializerState b)

type SnapTest b = StateT (SnapState b) IO

instance Example (SnapTest b ()) where
  type Arg (SnapTest b ()) = SnapState b
  evaluateExample s _ cb _ =
    do mv <- newEmptyMVar
       cb $ \st@(SnapState _ _ _ _) -> do ((),(SnapState r' _ _ _)) <- runStateT s st
                                          putMVar mv r'
       takeMVar mv

afterAll :: IO () -> SpecWith a -> SpecWith a
afterAll action = go
  where go spec = do forest <- runIO $ runSpecM spec
                     res <- runIO $ mapM countFlatten forest
                     let specs = map snd res
                     let count = foldr (+) 0 (map fst res)
                     mvar <- runIO $ newMVar count
                     after (\_ -> cleanup mvar) (fromSpecList specs)
        countFlatten :: SpecTree a -> IO (Int, SpecTree a)
        countFlatten (SpecGroup s t) =
          do (count, t') <- joinCount <$> mapM countFlatten t
             return (count, SpecGroup s t')
        countFlatten (BuildSpecs a) = do s <- a
                                         (count, s') <- joinCount <$> mapM countFlatten s
                                         return (count, BuildSpecs (return s'))
        countFlatten (SpecItem s i) = return (1, SpecItem s i)
        joinCount :: [(Int, b)] -> (Int, [b])
        joinCount = foldr (\(a,b) (c,d) -> (a + c, b:d)) (0, [])
        cleanup mv = modifyMVar mv $ \v -> if v == 1
                                              then action >>= return . (v,)
                                              else return (v - 1, ())

snap :: Handler b b () -> SnapletInit b b -> SpecWith (SnapState b) -> Spec
snap site app spec = do
  init <- runIO $ getSnaplet (Just "test") app
  case init of
    Left err -> error $ show err
    Right (snaplet, initstate) -> do
      afterAll (closeSnaplet initstate) $
        before (return (SnapState Success site snaplet initstate)) spec

get :: Text -> SnapTest b TestResponse
get path = runRequest (Test.get (T.encodeUtf8 path) M.empty)

setResult :: Result -> SnapTest b ()
setResult r = do (SnapState r' s a i) <- S.get
                 case r' of
                   Success -> S.put (SnapState r s a i)
                   Fail msg -> return ()


should200 :: TestResponse -> SnapTest b ()
should200 (Html _) = setResult Success
should200 (Other 200) = setResult Success
should200 r = setResult (Fail (show r))

shouldNot200 :: TestResponse -> SnapTest b ()
shouldNot200 (Html _) = setResult (Fail "Got Html back.")
shouldNot200 (Other 200) = setResult (Fail "Got Other with 200 back.")
shouldNot200 r = setResult Success

should404 :: TestResponse -> SnapTest b ()
should404 NotFound = setResult Success
should404 r = setResult (Fail (show r))

shouldNot404 :: TestResponse -> SnapTest b ()
shouldNot404 NotFound = setResult (Fail "Got NotFound back.")
shouldNot404 r = setResult Success

should300 :: TestResponse -> SnapTest b ()
should300 (Redirect _ _) = setResult Success
should300 r = setResult (Fail (show r))

shouldNot300 :: TestResponse -> SnapTest b ()
shouldNot300 (Redirect _ _) = setResult (Fail "Got Redirect back.")
shouldNot300 r = setResult Success

should300To :: Text -> TestResponse -> SnapTest b ()
should300To pth (Redirect _ to) | pth `T.isPrefixOf` to = setResult Success
should300To _ r = setResult (Fail (show r))

shouldNot300To :: Text -> TestResponse -> SnapTest b ()
shouldNot300To pth (Redirect _ to) | pth `T.isPrefixOf` to = setResult (Fail "Got Redirect back.")
shouldNot300To _ r = setResult Success

shouldHaveSelector :: TestResponse -> Text -> SnapTest b ()
shouldHaveSelector r@(Html body) selector =
  setResult $ if haveSelector' r selector
                then Success
                else (Fail msg)
  where msg = (T.unpack $ T.concat ["Html should have contained selector: ", selector, "\n\n", body])
shouldHaveSelector _ match = setResult (Fail (T.unpack $ T.concat ["Non-HTML body should have contained css selector: ", match]))

shouldNotHaveSelector :: TestResponse -> Text -> SnapTest b ()
shouldNotHaveSelector r@(Html body) selector =
  setResult $ if haveSelector' r selector
                then (Fail msg)
                else Success
  where msg = (T.unpack $ T.concat ["Html should not have contained selector: ", selector, "\n\n", body])
shouldNotHaveSelector _ _ = setResult Success

haveSelector' :: TestResponse -> Text -> Bool
haveSelector' (Html body) selector =
  case HXT.runLA (HXT.hread HXT.>>> HS.css (T.unpack selector)) (T.unpack body)  of
    [] -> False
    _ -> True
haveSelector' _ _ = False

shouldHaveText :: TestResponse -> Text -> SnapTest b ()
shouldHaveText (Html body) match =
  if T.isInfixOf match body
  then setResult Success
  else setResult (Fail $ T.unpack $ T.concat [body, "' contains '", match, "'."])
shouldHaveText _ match = setResult (Fail (T.unpack $ T.concat ["Body contains: ", match]))

shouldNotHaveText :: TestResponse -> Text -> SnapTest b ()
shouldNotHaveText (Html body) match =
  if T.isInfixOf match body
  then setResult (Fail $ T.unpack $ T.concat [body, "' contains '", match, "'."])
  else setResult Success
shouldNotHaveText _ _ = setResult Success

-- Internal helpers

runRequest :: RequestBuilder IO () -> SnapTest b TestResponse
runRequest req = do
  (SnapState res site app is) <- S.get
  res <- liftIO $ runHandlerSafe req site app is
  case res of
    Left err -> do
      error $ T.unpack err
    Right response -> do
      case rspStatus response of
        404 -> return NotFound
        200 -> do
          body <- liftIO $ getResponseBody response
          return $ Html $ T.decodeUtf8 body
        _ -> if (rspStatus response) >= 300 && (rspStatus response) < 400
                then do let url = fromMaybe "" $ getHeader "Location" response
                        return (Redirect (rspStatus response) (T.decodeUtf8 url))
                else return (Other (rspStatus response))




runHandlerSafe :: RequestBuilder IO ()
               -> Handler b b v
               -> Snaplet b
               -> InitializerState b
               -> IO (Either Text Response)
runHandlerSafe req site s is =
  catch (runHandler' s is req site) (\(e::SomeException) -> return $ Left (T.pack $ show e))

evalHandlerSafe :: Handler b b v
                -> Snaplet b
                -> InitializerState b
                -> IO (Either Text v)
evalHandlerSafe act s is =
  catch (evalHandler' s is (Test.get "" M.empty) act) (\(e::SomeException) -> return $ Left (T.pack $ show e))
