
//
//  CFSocketClientTransport.swift
//  swiftli
//
//  Created by Sriram Panyam on 12/14/15.
//  Copyright © 2015 Sriram Panyam. All rights reserved.
//

import Foundation


public class CFSocketClientTransport : ClientTransport {
    var connection : Connection?
    var clientSocketNative : CFSocketNativeHandle
    var clientSocket : CFSocket?
    var transportRunLoop : CFRunLoop
    var readsAreEdgeTriggered = true
    var writesAreEdgeTriggered = true
    var runLoopSource : CFRunLoopSource?
    
    init(_ clientSock : CFSocketNativeHandle, runLoop: CFRunLoop?) {
        clientSocketNative = clientSock;
        if let theLoop = runLoop {
            transportRunLoop = theLoop
        } else {
            transportRunLoop = runLoop!
        }

        initSockets();
        
        enableSocketFlag(kCFSocketCloseOnInvalidate)
        setReadyToWrite()
        setReadyToRead()
    }
    
    /**
     * Perform an action in run loop corresponding to this client transport.
     */
    public func performBlock(block: (() -> Void))
    {
//        let currRunLoop = CFRunLoopGetCurrent()
//        if transportRunLoop == currRunLoop {
//            block()
//        } else {
            CFRunLoopPerformBlock(transportRunLoop, kCFRunLoopCommonModes, block)
//        }
    }

    /**
     * Called to close the transport.
     */
    public func close() {
        CFRunLoopRemoveSource(transportRunLoop, runLoopSource, kCFRunLoopCommonModes)
    }
    
    /**
     * Called to indicate that the connection is ready to write data
     */
    public func setReadyToWrite() {
        enableSocketFlag(kCFSocketAutomaticallyReenableWriteCallBack)
    }
    
    /**
     * Called to indicate that the connection is ready to read data
     */
    public func setReadyToRead() {
        enableSocketFlag(kCFSocketAutomaticallyReenableReadCallBack)
    }
    
    /**
     * Indicates to the transport that no writes are required as yet and to not invoke the write callback
     * until explicitly required again.
     */
    private func clearReadyToWrite() {
        disableSocketFlag(kCFSocketAutomaticallyReenableWriteCallBack)
    }
    
    /**
     * Indicates to the transport that no writes are required as yet and to not invoke the write callback
     * until explicitly required again.
     */
    private func clearReadbale() {
        disableSocketFlag(kCFSocketAutomaticallyReenableReadCallBack)
    }
    
    private func initSockets()
    {
        var socketContext = CFSocketContext(version: 0, info: self.asUnsafeMutableVoid(), retain: nil, release: nil, copyDescription: nil)
        withUnsafePointer(&socketContext) {
            clientSocket = CFSocketCreateWithNative(kCFAllocatorDefault,
                clientSocketNative,
                CFSocketCallBackType.ReadCallBack.rawValue | CFSocketCallBackType.WriteCallBack.rawValue,
                clientSocketCallback,
                UnsafePointer<CFSocketContext>($0))
        }
        runLoopSource = CFSocketCreateRunLoopSource(kCFAllocatorDefault, clientSocket, 0)
        CFRunLoopAddSource(transportRunLoop, runLoopSource, kCFRunLoopDefaultMode)
    }

    private func asUnsafeMutableVoid() -> UnsafeMutablePointer<Void>
    {
        let selfAsOpaque = Unmanaged<CFSocketClientTransport>.passUnretained(self).toOpaque()
        let selfAsVoidPtr = UnsafeMutablePointer<Void>(selfAsOpaque)
        return selfAsVoidPtr
    }
    
    func connectionClosed() {
        connection?.connectionClosed()
    }
    
    func hasBytesAvailable() {
        // It is safe to call CFReadStreamRead; it won’t block because bytes are available.
        if let (buffer, length) = connection?.readDataRequested() {
            if length > 0 {
                let bytesRead = CFReadStreamRead(readStream, buffer, length);
                if bytesRead > 0 {
                    connection?.dataReceived(bytesRead)
                } else if bytesRead < 0 {
                    handleReadError()
                }
                return
            }
        }
//        clearReadyToRead()
    }
    
    func canAcceptBytes() {
        if let (buffer, length) = connection?.writeDataRequested() {
            if length > 0 {
                let data = CFDataCreate(kCFAllocatorDefault, buffer, length);
                let numWritten = CFSocketSendData(clientSocket, nil, data, 3600)
                if numWritten > 0 {
                    connection?.dataWritten(numWritten)
                } else if numWritten < 0 {
                    // error?
                    handleWriteError()
                }
                
                if numWritten >= 0 && numWritten < length {
                    // only partial data written so dont clear writeable.
                    // if this is the case then for an edge triggered API
                    // we have to ensure that canAcceptBytes will eventually 
                    // get called.  So kick it off later on.
                    // TODO: ensure that we have some kind of backoff so that 
                    // these async triggers dont flood the run loop if the write
                    // stream is backed
                    if writesAreEdgeTriggered {
                        CFRunLoopPerformBlock(transportRunLoop, kCFRunLoopCommonModes) {
                            self.canAcceptBytes()
                        }
                    }
                    return
                }
            }
        }
        
        // no more bytes so clear writeable
        clearReadyToWrite()
    }
    
    func handleReadError() {
//        let error = CFReadStreamGetError(readStream);
//        print("Read error: \(error)")
//        connection?.receivedReadError(SocketErrorType(domain: (error.domain as NSNumber).stringValue, code: Int(error.error), message: ""))
        close()
    }
    
    func handleWriteError() {
//        let error = CFWriteStreamGetError(writeStream);
//        print("Write error: \(error)")
//        connection?.receivedWriteError(SocketErrorType(domain: (error.domain as NSNumber).stringValue, code: Int(error.error), message: ""))
        close()
    }
    
    func enableSocketFlag(flag: UInt) {
        var flags = CFSocketGetSocketFlags(clientSocket)
        flags |= flag
        CFSocketSetSocketFlags(clientSocket, flags)
    }

    func disableSocketFlag(flag: UInt) {
        var flags = CFSocketGetSocketFlags(clientSocket)
        flags &= ~flag
        CFSocketSetSocketFlags(clientSocket, flags)
    }
}

/**
 * Callback for the read stream when data is available or errored.
 */
func readCallback(readStream: CFReadStream!, eventType: CFStreamEventType, info: UnsafeMutablePointer<Void>) -> Void
{
    let socketConnection = Unmanaged<CFSocketClientTransport>.fromOpaque(COpaquePointer(info)).takeUnretainedValue()
    if eventType == CFStreamEventType.HasBytesAvailable {
        socketConnection.hasBytesAvailable()
    } else if eventType == CFStreamEventType.EndEncountered {
        socketConnection.connectionClosed()
    } else if eventType == CFStreamEventType.ErrorOccurred {
        socketConnection.handleReadError()
    }
}

/**
 * Callback for the write stream when data is available or errored.
 */
func writeCallback(writeStream: CFWriteStream!, eventType: CFStreamEventType, info: UnsafeMutablePointer<Void>) -> Void
{
    let socketConnection = Unmanaged<CFSocketClientTransport>.fromOpaque(COpaquePointer(info)).takeUnretainedValue()
    if eventType == CFStreamEventType.CanAcceptBytes {
        socketConnection.canAcceptBytes();
    } else if eventType == CFStreamEventType.EndEncountered {
        socketConnection.connectionClosed()
    } else if eventType == CFStreamEventType.ErrorOccurred {
        socketConnection.handleWriteError()
    }
}


private func clientSocketCallback(socket: CFSocket!,
    callbackType: CFSocketCallBackType,
    address: CFData!,
    data: UnsafePointer<Void>,
    info: UnsafeMutablePointer<Void>)
{
    if (callbackType == CFSocketCallBackType.ReadCallBack)
    {
        let clientTransport = Unmanaged<CFSocketClientTransport>.fromOpaque(COpaquePointer(info)).takeUnretainedValue()
        clientTransport.hasBytesAvailable()
    }
    else if (callbackType == CFSocketCallBackType.WriteCallBack)
    {
        print("Write callback")
        let clientTransport = Unmanaged<CFSocketClientTransport>.fromOpaque(COpaquePointer(info)).takeUnretainedValue()
        clientTransport.canAcceptBytes()
    }
}
