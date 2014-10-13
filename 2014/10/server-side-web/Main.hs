{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE TemplateHaskell #-}

module Main where


import Control.Applicative                  ((<$>))
import Control.Monad.IO.Class               (liftIO)
import Control.Monad.Reader                 (ask)
import Data.Aeson                           (ToJSON, FromJSON, object, (.=))
import Data.ByteString                      (ByteString)
import Data.List                            (sortBy)
import Data.Ord                             (comparing)
import Data.SafeCopy                        (deriveSafeCopy, base)
import Data.Typeable                        (Typeable)
import GHC.Generics                         (Generic)
import Network.HTTP.Types                   (status404)
import Network.Wai.Middleware.RequestLogger (logStdoutDev)

import Data.Acid ( Update
                 , Query
                 , makeAcidic
                 , openLocalState --From
                 , update
                 , query
                 )

import Web.Scotty ( scotty
                  , get
                  , post
                  , body
                  , param
                  , html
                  , json
                  , middleware
                  , status
                  )

import qualified Data.IntMap as IntMap
import qualified Control.Monad.State as State


-- https://ocharles.org.uk/blog/posts/2013-12-14-24-days-of-hackage-acid-state.html

-- | Messages
data Message = Message { content :: ByteString
                       , _id :: Int
                       }
  deriving (Show, Generic, Typeable)

instance ToJSON Message

data MessageDb = MessageDb { allMessages :: IntMap.IntMap Message }
  deriving (Typeable)


orderedMessages :: Query MessageDb [Message]
orderedMessages =
  sortBy (comparing _id) . IntMap.elems . allMessages <$> ask
  
messageById :: Int -> Query MessageDb (Maybe Message)
messageById _id = do
  db <- ask
  return (IntMap.lookup _id (allMessages db))


addContent :: ByteString -> Update MessageDb Message
addContent content = do
    (MessageDb db) <- State.get
    let (message, db') = case IntMap.maxViewWithKey db of
          Just ((max, _), _) ->
            let _id = (max + 1)
                message = Message content _id
            in (message, IntMap.insert _id message db)
          Nothing ->
            let _id = 1
                message = Message content _id
            in (message, IntMap.singleton _id message)
    State.put $ MessageDb db'
    return message


$(deriveSafeCopy 0 'base ''Message)
$(deriveSafeCopy 0 'base ''MessageDb)
$(makeAcidic ''MessageDb ['orderedMessages, 'addContent, 'messageById])


acidMain :: IO ()
acidMain = do
  state <- openLocalState (MessageDb IntMap.empty)

  update state (AddContent "ENOMISSLES")

  -- allMessages <- query state OrderedMessages
  message <- query state $ MessageById 1
  print message


-- https://github.com/scotty-web/scotty/blob/master/examples/reader.hs

-- | Web server:
main = scotty 3000 $ do
    state <- liftIO $ openLocalState (MessageDb IntMap.empty)
    middleware logStdoutDev

    get "/messages" $ do
        allMessages <- liftIO $ query state OrderedMessages
        json $ object ["messages" .= allMessages]

    get "/messages/:id" $ do
        _id <- param "id"
        mmessage <- liftIO $ query state $ MessageById (read _id :: Int)
        case mmessage of
            Nothing -> json $ object ["messages" .= ([] :: [Message])]
            Just message -> do
                status status404
                json $ object ["messages" .= [message]]

    post "/messages" $ do
        content <- param "content"
        message <- liftIO $ update state $ AddContent content
        json $ object ["messages" .= [message]]
