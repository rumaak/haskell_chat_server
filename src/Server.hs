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
import                  System.Environment
import                  Data.Tuple.Extra                (uncurry3)
import                  Text.Read                       (readMaybe)

-- cyclical buffer and related variables
-- note: the naming would be more precise if we prepended `Shared` to each
type CyclicalBuffer = TVar (A.Array Int T.Text)
type BufferPointer = TVar Int
type BufferCount = TVar Int
type BufferMutex = MVar ()

-- storing last n messages using cyclical buffer
data MessageHistory = MessageHistory {
    buffer :: CyclicalBuffer,
    pointer :: BufferPointer, -- first message position
    count :: BufferCount, -- number of messages in buffer
    mutex :: BufferMutex
}

-- channel containing messages broadcasted to a room
type Broadcast = TChan T.Text

data Room = Room {
    name :: String,
    password :: String,
    memorySize :: Int,
    messages :: MessageHistory,
    broadcast :: Broadcast
}

-- initialize server, accept and handle incoming requests
serve :: IO ()
serve = withSocketsDo $ do
    -- initialize server according to a configuration file
    config <- getConfigName
    rooms <- parseConfig config

    -- listen to incoming requests
    listen (Host "127.0.0.1") "8000" $ \(listenSocket, listenAddr) -> do
        putStrLn $ "Listening for TCP connections at " ++ show listenAddr

        -- handling single TCP connection
        forever . acceptFork listenSocket $ \(acceptSocket, acceptAddr) -> do
            putStrLn $ "Accepted incoming connection from " ++ show acceptAddr

            -- what room does the user want to join
            maybeRoom <- roomPrompt acceptSocket rooms
            
            -- what name does the user want to use
            maybeName <- namePrompt acceptSocket
            send acceptSocket "Connected succesfuly!\n"

            case (maybeRoom, maybeName) of
                (Just room, Just name) -> do
                    let bchan = broadcast room

                    -- partial function applications
                    let 
                        bufferInsert = insertPrevious room
                        bufferSend = sendPrevious acceptSocket room

                    messageJoined name bchan
                    finally     (handleClient acceptSocket name bchan bufferInsert bufferSend)
                                (messageLeft name bchan)
                _ -> return ()

            putStrLn $ "Closing connection from " ++ show acceptAddr

-- use specified config file or fall back to default
getConfigName :: IO String
getConfigName = do
    args <- getArgs
    if (length args) < 1
        then return "server_conf/rooms_default.conf"
        else return $ args!!0 

-- for each properly specified room in config, create corresponding room
parseConfig :: FilePath -> IO [Room]
parseConfig filepath = do
    lines <- fmap lines (readFile filepath)
    linesSplit <- return $ map (splitOn ":") lines
    mapM (uncurry3 createRoom) [tup line | line <- linesSplit, check line]
    where
        tup l = (l!!0, l!!1, read (l!!2) :: Int)
        check l = ((length l) == 3) && (readable (l!!2))

-- whether String can be read as an Int
readable :: String -> Bool
readable s = case readMaybe s :: Maybe Int of
    Just _ -> True
    Nothing -> False

-- initialize shared variables for single room identified by name and password
createRoom :: String -> String -> Int -> IO Room
createRoom name passwd memSize = do
    bchanR <- newBroadcastTChanIO :: IO (TChan T.Text)

    -- shared cyclical buffer and related variables
    previousR <- newTVarIO $ A.array (0,memSize-1) [(i, T.pack "")|i<-[0..(memSize-1)]]
    previousPointerR <- newTVarIO 0
    previousCountR <- newTVarIO 0

    -- to prevent simultaneous access to cyclical buffer from multiple threads
    mutexR <- newEmptyMVar :: IO (MVar ())
    putMVar mutexR ()

    let history = MessageHistory previousR previousPointerR previousCountR mutexR
    return $ Room name passwd memSize history bchanR

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
                then return True
                else do
                    send socket "Wrong password!\n"
                    passwordPrompt socket room

        Nothing -> return False

-- return room with given name if it exists
getRoom :: [Room] -> String -> Maybe Room
getRoom rooms rName = L.find check rooms
    where 
        check room = (name room) == rName

-- return Just name specified by user or Nothing if he disconnects
namePrompt :: Socket -> IO (Maybe T.Text)
namePrompt socket = do 
    send socket "Choose a nickname: "
    maybeResponse <- recv socket 4096
    case maybeResponse of
        Just response -> case E.decodeUtf8' response of
            -- decoding failed
            Left _ -> do 
                return Nothing
            -- decoding succeeded
            Right name -> 
                return $ Just $ T.strip $ name

        Nothing -> return Nothing

-- insert message to a cyclical buffer (contains last n messages)
insertPrevious :: Room -> T.Text -> IO ()
insertPrevious room t = do
    let 
        memSize = memorySize room
        previous = buffer $ messages room
        previousPointer = pointer $ messages room
        previousCount = count $ messages room
        mx = mutex $ messages room

    -- lock
    takeMVar mx 

    arr <- readTVarIO previous
    pointer <- readTVarIO previousPointer
    count <- readTVarIO previousCount

    newArr <- return $ arr // [(pointer,t)]
    newPointer <- return $ (pointer + 1) `mod` memSize
    newCount <- return $ min (count + 1) memSize
    
    atomically $ writeTVar previous newArr
    atomically $ writeTVar previousPointer newPointer
    atomically $ writeTVar previousCount newCount

    -- unlock
    putMVar mx ()

-- send contents of cyclical buffer to user specified by socket
sendPrevious :: Socket -> Room -> IO () 
sendPrevious socket room = do
    let 
        memSize = memorySize room
        previous = buffer $ messages room
        previousPointer = pointer $ messages room
        previousCount = count $ messages room
        mx = mutex $ messages room

    -- lock
    takeMVar mx 

    arr <- readTVarIO previous
    pointer <- readTVarIO previousPointer
    count <- readTVarIO previousCount

    -- return sequence of indices reflecting correct chronological order of
    -- messages in buffer, then send them in this order
    indices <- return [(idx + pointer + (memSize - count)) `mod` memSize | idx <- [0..(count-1)]]
    mapM_ ((send socket) . E.encodeUtf8 . (\i -> arr!i)) indices

    -- unlock
    putMVar mx ()

-- send message to a channel
message :: [T.Text] -> TChan T.Text -> IO ()
message ts bchan = atomically $ writeTChan bchan (T.concat ts)

-- broadcast that given user has left
messageLeft :: T.Text -> (TChan T.Text) -> IO ()
messageLeft name bchan = message text bchan
    where text = [name,(T.pack " has left.\n")]

-- broadcast that given user has joined
messageJoined :: T.Text -> (TChan T.Text) -> IO ()
messageJoined name bchan = message text bchan
    where text = [name,(T.pack " has just arrived!\n")]

-- broadcast a message to a room and write it to the cyclical buffer
messageUser :: T.Text -> T.Text -> TChan T.Text -> (T.Text -> IO ()) -> IO ()
messageUser name t bchan bufferInsert = do
    message text bchan
    bufferInsert $ T.concat text
    where 
        noNewln = T.replace (T.pack "\n") T.empty t 
        text = [(T.pack "["),name,(T.pack "]: "),noNewln,"\n"]

-- handle sending messages from client to server and vice versa
handleClient :: Socket -> T.Text -> TChan T.Text -> (T.Text -> IO ()) -> IO () -> IO ()
handleClient acceptSocket name bchan bufferInsert bufferSend = do
    dchan <- atomically $ dupTChan bchan
    tid <- deliverMessages acceptSocket dchan bufferSend
    storeMessages acceptSocket name bchan bufferInsert
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
storeMessages :: Socket -> T.Text -> TChan T.Text -> (T.Text -> IO ()) -> IO ()
storeMessages socket name bchan bufferInsert = do
    maybeIncoming <- recv socket 4096
    case maybeIncoming of
        Just incoming -> case E.decodeUtf8' incoming of
            -- decoding failed
            Left _ -> do 
                return ()
            -- decoding succeeded
            Right text -> do
                messageUser name (E.decodeUtf8 incoming) bchan bufferInsert
                storeMessages socket name bchan bufferInsert
        Nothing -> return ()















