{-# LANGUAGE OverloadedStrings #-}

module Server where

import           Control.Monad                (forever)
import           Network.Simple.TCP           as S

-- Send back what was sent to the server
simpleCopy :: IO ()
simpleCopy = S.withSocketsDo $ do
    S.serve (S.Host "127.0.0.1") "8000" $ \(connectionSocket, remoteAddr) -> do
        putStrLn $ "TCP connection established from " ++ show remoteAddr
        forever $ do
            maybeIncoming <- recv connectionSocket 4096
            case maybeIncoming of
                Just incoming -> do
                    send connectionSocket incoming
                Nothing -> return ()

