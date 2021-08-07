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
import                  Data.List                       as L
import                  Data.List.Split

-- Note: the naming would be more precise if we prepended `Shared` to each
type CyclicalBuffer = TVar (A.Array Int T.Text)
type BufferPointer = TVar Int
type BufferCount = TVar Int
type BufferMutex = MVar ()

-- storing last n messages using cyclical buffer
data MessageHistory = MessageHistory {
    buffer :: CyclicalBuffer,
    pointer :: BufferPointer,
    count :: BufferCount,
    mutex :: BufferMutex
}

-- channel containing messages broadcasted to a room
type Broadcast = TChan T.Text

data Room = Room {
    name :: String,
    password :: String,
    messages :: MessageHistory,
    broadcast :: Broadcast
}

-- broadcast messages to all connected users + send stored messages
serve :: IO ()
serve = withSocketsDo $ do
    rooms <- parseConfig "server_conf/rooms_default.conf"

    listen (Host "127.0.0.1") "8000" $ \(listenSocket, listenAddr) -> do
        putStrLn $ "Listening for TCP connections at " ++ show listenAddr
        forever . acceptFork listenSocket $ \(acceptSocket, acceptAddr) -> do
            putStrLn $ "Accepted incoming connection from " ++ show acceptAddr

            -- what room does the user want to join
            maybeRoom <- roomPrompt acceptSocket rooms

            case maybeRoom of
                Just room -> do
                    -- room shared variables
                    let 
                        bchan = broadcast room
                        
                        previous = buffer $ messages room
                        previousPointer = pointer $ messages room
                        previousCount = count $ messages room
                        mx = mutex $ messages room

                    -- partial function applications
                    let 
                        bufferInsert = insertPrevious previous previousPointer previousCount mx
                        bufferSend = sendPrevious acceptSocket previous previousPointer previousCount mx

                    messageJoined acceptAddr bchan
                    finally     (handleClient acceptSocket acceptAddr bchan bufferInsert bufferSend)
                                (messageLeft acceptAddr bchan)
                Nothing -> return ()

            putStrLn $ "Closing connection from " ++ show acceptAddr

-- for each properly specified room in config, create corresponding room
parseConfig :: FilePath -> IO [Room]
parseConfig filepath = do
    lines <- fmap lines (readFile filepath)
    linesSplit <- return $ map (splitOn ":") lines
    mapM (uncurry createRoom) [((line!!0), (line!!1)) | line <- linesSplit, (length line) == 2]

-- initialize shared variables for single room identified by name and password
createRoom :: String -> String -> IO Room
createRoom name passwd = do
    bchanR <- newBroadcastTChanIO :: IO (TChan T.Text)

    -- shared cyclical buffer and related variables
    previousR <- newTVarIO $ A.array (0,4) [(i, T.pack "")|i<-[0..4]]
    previousPointerR <- newTVarIO 0
    previousCountR <- newTVarIO 0

    -- to prevent simultaneous access to cyclical buffer from multiple threads
    mutexR <- newEmptyMVar :: IO (MVar ())
    putMVar mutexR ()

    let history = MessageHistory previousR previousPointerR previousCountR mutexR
    return $ Room name passwd history bchanR

-- return Just roomName specified by user or Nothing if he disconnects
roomPrompt :: Socket -> [Room] -> IO (Maybe Room)
roomPrompt socket rooms = do
    send socket "Insert name of the room you would like to join: "
    maybeResponse <- recv socket 4096
    case maybeResponse of
        Just response -> case E.decodeUtf8' response of
            -- decoding failed
            Left _ -> do 
                return Nothing
            -- decoding succeeded
            Right rName -> 
                case getRoom rooms (T.unpack $ T.strip $ rName) of
                    Just room -> do
                        knowsPasswd <- passwordPrompt socket room
                        if knowsPasswd 
                        then return $ Just room
                        else
                            return Nothing
                    Nothing -> do
                        send socket "Room does not exist!\n"
                        roomPrompt socket rooms

        Nothing -> return Nothing

-- return True if user passes correct password, False otherwise
passwordPrompt :: Socket -> Room -> IO Bool
passwordPrompt socket room = do
    send socket "Insert room password: "
    maybeResponse <- recv socket 4096
    case maybeResponse of
        Just response -> case E.decodeUtf8' response of
            -- decoding failed
            Left _ -> do 
                return False
            -- decoding succeeded
            Right passwd -> 
                if (password room) == (T.unpack $ T.strip $ passwd)
                then do
                    send socket "Connected succesfuly!\n"
                    return True
                else do
                    send socket "Wrong password!\n"
                    passwordPrompt socket room

        Nothing -> return False

-- return room with given name if it exists
getRoom :: [Room] -> String -> Maybe Room
getRoom rooms rName = L.find check rooms
    where 
        check room = (name room) == rName

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















