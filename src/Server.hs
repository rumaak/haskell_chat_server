{-# LANGUAGE OverloadedStrings #-}

module Server where

import                  Control.Exception               (finally)
import                  Control.Monad                   (forever)
import                  Control.Monad.STM               (atomically)
import                  Control.Concurrent              (forkIO,
                                                        killThread,
                                                        ThreadId)
import                  Control.Concurrent.STM.TBQueue  (TBQueue,
                                                        newTBQueueIO,
                                                        writeTBQueue,
                                                        readTBQueue)
import                  Control.Concurrent.STM.TChan    (TChan,
                                                        newBroadcastTChanIO,
                                                        dupTChan,
                                                        readTChan,
                                                        writeTChan)
import                  Network.Simple.TCP              as S
import qualified        Data.Text                       as T
import qualified        Data.Text.Encoding              as E

-- broadcast incoming messages to all users using BroadcastTChan
broadcastMessages :: IO ()
broadcastMessages = withSocketsDo $ do
    bchan <- newBroadcastTChanIO :: IO (TChan T.Text)
    listen (Host "127.0.0.1") "8000" $ \(listenSocket, listenAddr) -> do
        putStrLn $ "Listening for TCP connections at " ++ show listenAddr
        forever . acceptFork listenSocket $ \(acceptSocket, acceptAddr) -> do
            putStrLn $ "Accepted incoming connection from " ++ show acceptAddr
            dchan <- atomically $ dupTChan bchan
            messageJoined acceptAddr bchan
            finally     (handleClient acceptSocket acceptAddr bchan dchan)
                        (messageLeft acceptAddr bchan)
            putStrLn $ "Closing connection from " ++ show acceptAddr

-- send message to a channel
message :: [T.Text] -> TChan T.Text -> IO ()
message ts bchan = atomically $ writeTChan bchan (T.concat ts)

messageLeft :: SockAddr -> (TChan T.Text) -> IO ()
messageLeft addr bchan = message text bchan
    where text = [(T.pack $ show addr),(T.pack " has left.\n")]

messageJoined :: SockAddr -> (TChan T.Text) -> IO ()
messageJoined addr bchan = message text bchan
    where text = [(T.pack $ show addr),(T.pack " has just arrived!\n")]

messageUser :: SockAddr -> T.Text -> (TChan T.Text) -> IO ()
messageUser addr t bchan = message text bchan
    where 
        noNewln = T.replace (T.pack "\n") T.empty t 
        text = [(T.pack "["),(T.pack $ show addr),(T.pack "]: "),noNewln,"\n"]

-- handle sending messages from client to server and vice versa
handleClient :: Socket -> SockAddr -> (TChan T.Text) -> (TChan T.Text) -> IO ()
handleClient acceptSocket acceptAddr bchan dchan= do
    tid <- deliverMessages acceptSocket dchan
    storeMessages acceptSocket acceptAddr bchan
    killThread tid

-- check TChan for new messages, send them to given client, return id of thread
deliverMessages :: Socket -> (TChan T.Text) -> IO ThreadId
deliverMessages socket dchan = do
    tid <- forkIO . forever $ do
        newMessage <- atomically $ readTChan dchan
        send socket (E.encodeUtf8 newMessage)
    return tid

-- store message from given client into TChan
storeMessages :: Socket -> SockAddr -> (TChan T.Text) -> IO ()
storeMessages socket addr bchan = do
    maybeIncoming <- recv socket 4096
    case maybeIncoming of
        Just incoming -> case E.decodeUtf8' incoming of
            -- decoding failed
            Left _ -> do 
                return ()
            -- decoding succeeded
            Right text -> do
                messageUser addr (E.decodeUtf8 incoming) bchan
                storeMessages socket addr bchan
        Nothing -> return ()
















