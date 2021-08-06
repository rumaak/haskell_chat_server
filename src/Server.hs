{-# LANGUAGE OverloadedStrings #-}

module Server where

import                  Control.Exception               (finally)
import                  Control.Monad                   (forever)
import                  Control.Monad.STM               (atomically)
import                  Control.Concurrent              (forkIO,
                                                        killThread,
                                                        ThreadId,
                                                        MVar,
                                                        newEmptyMVar,
                                                        putMVar,
                                                        takeMVar)
import                  Control.Concurrent.STM.TChan    (TChan,
                                                        newBroadcastTChanIO,
                                                        newTChanIO,
                                                        dupTChan,
                                                        cloneTChan,
                                                        readTChan,
                                                        writeTChan,
                                                        tryReadTChan)
import                  Control.Concurrent.STM.TVar     (newTVarIO,
                                                        readTVarIO,
                                                        writeTVar,
                                                        TVar)
import                  Network.Simple.TCP              as S
import qualified        Data.Text                       as T
import qualified        Data.Text.Encoding              as E
import                  Data.Array                      as A

-- broadcast messages to all connected users + send stored messages
serve :: IO ()
serve = withSocketsDo $ do
    bchan <- newBroadcastTChanIO :: IO (TChan T.Text)

    -- shared cyclical buffer and related variables
    previous <- newTVarIO $ A.array (0,4) [(i, T.pack "")|i<-[0..4]]
    previous_pointer <- newTVarIO 0
    previous_count <- newTVarIO 0

    -- to prevent simultaneous access to cyclical buffer from multiple threads
    mutex <- newEmptyMVar :: IO (MVar ())
    putMVar mutex ()

    listen (Host "127.0.0.1") "8000" $ \(listenSocket, listenAddr) -> do
        putStrLn $ "Listening for TCP connections at " ++ show listenAddr
        forever . acceptFork listenSocket $ \(acceptSocket, acceptAddr) -> do
            putStrLn $ "Accepted incoming connection from " ++ show acceptAddr

            -- partial function applications
            let 
                bufferInsert = insertPrevious previous previous_pointer previous_count mutex
                bufferSend = sendPrevious acceptSocket previous previous_pointer previous_count mutex

            messageJoined acceptAddr bchan
            finally     (handleClient acceptSocket acceptAddr bchan bufferInsert bufferSend)
                        (messageLeft acceptAddr bchan)
            putStrLn $ "Closing connection from " ++ show acceptAddr

-- insert message to a cyclical buffer (contains last n messages)
insertPrevious :: TVar (Array Int T.Text) -> TVar Int -> TVar Int -> MVar () -> T.Text -> IO ()
insertPrevious previous previous_pointer previous_count mutex t = do
    takeMVar mutex 

    arr <- readTVarIO previous
    pointer <- readTVarIO previous_pointer
    count <- readTVarIO previous_count

    new_arr <- return $ arr // [(pointer,t)]
    new_pointer <- return $ (pointer + 1) `mod` 5
    new_count <- return $ min (count + 1) 5
    
    atomically $ writeTVar previous new_arr
    atomically $ writeTVar previous_pointer new_pointer
    atomically $ writeTVar previous_count new_count

    putMVar mutex ()

-- send contents of cyclical buffer to user specified by socket
sendPrevious :: Socket -> TVar (Array Int T.Text) -> TVar Int -> TVar Int -> MVar () -> IO () 
sendPrevious socket previous previous_pointer previous_count mutex = do
    takeMVar mutex 

    arr <- readTVarIO previous
    pointer <- readTVarIO previous_pointer
    count <- readTVarIO previous_count

    indices <- return [(idx + pointer + (5 - count)) `mod` 5 | idx <- [0..(count-1)]]
    mapM_ ((send socket) . E.encodeUtf8 . (\i -> arr!i)) indices

    putMVar mutex ()

-- send message to a channel
message :: [T.Text] -> TChan T.Text -> IO ()
message ts bchan = atomically $ writeTChan bchan (T.concat ts)

messageLeft :: SockAddr -> (TChan T.Text) -> IO ()
messageLeft addr bchan = message text bchan
    where text = [(T.pack $ show addr),(T.pack " has left.\n")]

messageJoined :: SockAddr -> (TChan T.Text) -> IO ()
messageJoined addr bchan = message text bchan
    where text = [(T.pack $ show addr),(T.pack " has just arrived!\n")]

messageUser :: SockAddr -> T.Text -> TChan T.Text -> (T.Text -> IO ()) -> IO ()
messageUser addr t bchan bufferInsert = do
    message text bchan
    bufferInsert $ T.concat text
    where 
        noNewln = T.replace (T.pack "\n") T.empty t 
        text = [(T.pack "["),(T.pack $ show addr),(T.pack "]: "),noNewln,"\n"]

-- handle sending messages from client to server and vice versa
handleClient :: Socket -> SockAddr -> TChan T.Text -> (T.Text -> IO ()) -> IO () -> IO ()
handleClient acceptSocket acceptAddr bchan bufferInsert bufferSend = do
    dchan <- atomically $ dupTChan bchan
    tid <- deliverMessages acceptSocket dchan bufferSend
    storeMessages acceptSocket acceptAddr bchan bufferInsert
    killThread tid

-- send messages in buffer to client, check TChan for new messages, send them to given 
-- client, return id of thread
deliverMessages :: Socket -> TChan T.Text -> IO () -> IO ThreadId
deliverMessages socket dchan bufferSend = do
    bufferSend
    tid <- forkIO . forever $ do
        newMessage <- atomically $ readTChan dchan
        send socket (E.encodeUtf8 newMessage)
    return tid

-- store message from given client into TChan and cyclical buffer
storeMessages :: Socket -> SockAddr -> TChan T.Text -> (T.Text -> IO ()) -> IO ()
storeMessages socket addr bchan bufferInsert = do
    maybeIncoming <- recv socket 4096
    case maybeIncoming of
        Just incoming -> case E.decodeUtf8' incoming of
            -- decoding failed
            Left _ -> do 
                return ()
            -- decoding succeeded
            Right text -> do
                messageUser addr (E.decodeUtf8 incoming) bchan bufferInsert
                storeMessages socket addr bchan bufferInsert
        Nothing -> return ()















