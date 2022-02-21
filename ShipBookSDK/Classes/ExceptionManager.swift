//
//  CrashManager.swift
//  ShipBook
//
//  Created by Elisha Sterngold on 19/11/2017.
//  Copyright © 2018 ShipBook Ltd. All rights reserved.
//
#if canImport(UIKit)
import Foundation
import MachO.dyld

class ExceptionManager {
  static let shared = ExceptionManager()
  let binaryImages: [BinaryImage]?
  var prefActions: []?
  func start(exception: Bool = true) {
    if (exception) {
      createException()
    }
  }
  
  private init() {
    print("binary images")
    let c = _dyld_image_count()
    var binaryImages: [BinaryImage] = Array.init()
    for i in 0..<c {
      let imageName = String(cString: _dyld_get_image_name(i))
      let imageNameEnding = URL(fileURLWithPath: imageName).lastPathComponent
      let header = _dyld_get_image_header(i);
      if let header = header {
        let info = NXGetArchInfoFromCpuType(header.pointee.cputype, header.pointee.cpusubtype);
        if let info = info {
          let arch = String(cString:info.pointee.name)
          let startAddress = Int(bitPattern: header)
          binaryImages.append(BinaryImage(startAddress: String(format: "%018p", startAddress), name: imageNameEnding, arch: arch, path: imageName))
        }
      }
    }
    self.binaryImages = binaryImages
  }

  public enum Signal : Int32, CaseIterable {
    case SIGABRT = 6
    case SIGILL = 4
    case SIGSEGV = 11
    case SIGFPE = 8
    case SIGBUS = 10
    case SIGPIPE = 13
    case SIGTRAP = 5
    
    
    var name: String {
      switch self {
      case .SIGABRT: return "SIGABRT"
      case .SIGILL: return "SIGILL"
      case .SIGSEGV: return "SIGSEGV"
      case .SIGFPE: return "SIGFPE"
      case .SIGBUS: return "SIGBUS"
      case .SIGPIPE: return "SIGPIPE"
      case .SIGTRAP: return "SIGTRAP"
      }
    }
  }
  
  typealias SigactionHandler = @convention(c) (Int32, UnsafeMutablePointer<__siginfo>?, UnsafeMutableRawPointer?) -> Void
  
  let signalHandler: SigactionHandler = { sig, siginfo, p in
    let signalName = String(cString: strsignal(sig))
    let callStackSymbols: [String] = Thread.callStackSymbols
    let signalObj  = Signal(rawValue: sig)
    let exceptionName =  signalObj != nil ? signalObj!.name : "No Name";
    let exception = Exception(name:exceptionName, reason: signalName, callStackSymbols: callStackSymbols, binaryImages: ExceptionManager.shared.binaryImages)
    let appenders = LogManager.shared.appenders //copying so that it can be changed in the middle
    for (_, appender) in LogManager.shared.appenders {
      appender.saveCrash(exception: exception)
    }

    signal(sig, SIG_DFL)
  }
  
  private func createException() {
    NSSetUncaughtExceptionHandler { exception in
      let callStackSymbols: [String] = exception.callStackSymbols
//      DispatchQueue.shipBook.sync {
        for (_, appender) in LogManager.shared.appenders {
          appender.push(log: Exception(name: exception.name.rawValue, reason: exception.reason, callStackSymbols: callStackSymbols, binaryImages: ExceptionManager.shared.binaryImages))
        }
//      }
    }
    
    var sigAction = sigaction()
    sigAction.sa_flags = SA_SIGINFO|SA_RESETHAND;
    sigAction.__sigaction_u.__sa_sigaction = signalHandler
    
    var sigActionPrev = sigaction()
    
    for sig in Signal.allCases {
      sigaction(sig.rawValue, &sigAction, &sigActionPrev)
      
    }
  }
}
#endif
