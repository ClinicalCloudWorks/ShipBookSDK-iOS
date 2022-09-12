//
//  SessionManager.swift
//  ShipBook
//
//  Created by Elisha Sterngold on 29/10/2017.
//  Copyright © 2018 ShipBook Ltd. All rights reserved.
//
#if canImport(UIKit)
import Foundation

let config = """
{
  "appenders" :
  [{
   "type" : "ConsoleAppender",
   "name" : "console",
   "config" : {
   "pattern" : "$message"
   }
   },
   {
   "type" : "SBCloudAppender",
   "name" : "cloud",
   "config" :
   {
   "maxTime" : 5,
   "flushSeverity" : "Warning"
   }
   }],
  "loggers" :
  [{
   "name" : "",
   "severity" : "Verbose",
   "appenderRef" : "console"
   },
   {
   "name" : "",
   "severity" : "Verbose",
   "appenderRef" : "cloud"
   }]
}
"""

let sdkBundle = Bundle(for: SessionManager.self)
class SessionManager {
  
  private var isInLoginRequest: Bool = false
  let configURL: URL
  let dirURL: URL
  var appKey: String?
  var appId: String?
  var token: String?
  var loginCompletion: ((_ sessionUrl: String)->())?
  
  private var _login: Login?
  var login: Login? {
    get {
      if let user = user { // adding user to the login
        _login?.user = user
      }
      return _login
    }
    set (login) {
      _login = login
    }
  }
  var user: User?
  
  var connected: Bool {
    get {
      if token != nil { return true }
      innerLogin()
      return false
    }
  }
  
  private init(){
  #if os(tvOS)
    let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
  #else
    let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
  #endif
    dirURL = dir!.appendingPathComponent("shipbook")
    configURL =  dirURL.appendingPathComponent("config.json")
  }
  
  static let shared = SessionManager()
  
  func login(appId: String, appKey: String, completion: ((_ sessionUrl: String)->())?, userConfig: URL?){ // should be called in the start of the app. if it would have async then there
                                                               // would be messages it missed
    if FileManager.default.fileExists(atPath: self.configURL.path) {
      self.readConfig(url: self.configURL)
    }
    else if let url = userConfig {
      self.readConfig(url: url)
    }
    else {
      self.readConfig(url: nil)
      try? FileManager.default.createDirectory(atPath: self.dirURL.path, withIntermediateDirectories: true, attributes: nil)
    }

    self.appKey = appKey
    self.appId = appId
    self.loginCompletion = completion
    self.login = Login(appId: appId,
                       appKey: appKey)
    
    self.innerLogin()
  }
  
  func logout() {
    DispatchQueue.shipBook.async {
      self.token = nil
      self.user = nil
      if self.login != nil {
        self.login = Login(appId: self.appId!,
                           appKey: self.appKey!)
      }
      self.innerLogin()
    }
  }
  
  func registerUser(userId: String,
                    userName: String?,
                    fullName: String?,
                    email: String?,
                    phoneNumber: String?,
                    additionalInfo: [String: String]?) {
    self.user = User(userId: userId,
                    userName: userName,
                    fullName: fullName,
                    email: email,
                    phoneNumber: phoneNumber,
                    additionalInfo: additionalInfo)
    if self.login != nil { //it is still not initialized the user was before the start
      DispatchQueue.shipBook.async {
        NotificationCenter.default.post(name: NotificationName.UserChange, object: self)
      }
    }
  }
  
  struct NoDataError: Error {
  }
  
  func readConfig(url: URL?) {
    do {
      let contents = try url != nil ? Data(contentsOf:url!) : Data(config.utf8)
      let config = try JSONDecoder().decode(ConfigResponse.self, from: contents)
      if !(config.exceptionReportDisabled == true) {
        ExceptionManager.shared.start()
      }
      if !(config.eventLoggingDisabled == true) {
        // EventManager.shared.enableViewController() it is bloating the logs
        EventManager.shared.enableAction()
        EventManager.shared.enableApp()
      }
      LogManager.shared.config(config)
    }
    catch {
      InnerLog.e(error.localizedDescription)
    }
  }
  
  private func innerLogin() {
    if !Reachability.isConnectedToNetwork() || isInLoginRequest || appKey == nil { return }
    isInLoginRequest = true
    let url = "auth/loginSdk"
    
    login?.deviceTime = Date()
    ConnectionClient.shared.request(url: url, data: login, method: HttpMethod.POST) { response in
      DispatchQueue.shipBook.async {
        self.isInLoginRequest = false
        if response.ok {
          do {
            guard response.data != nil else {
              throw NoDataError()
            }
            let login = try ConnectionClient.jsonDecoder.decode(LoginResponse.self, from: response.data!)
            self.token = login.token
            
            self.loginCompletion?(login.sessionUrl)
            
            LogManager.shared.config(login.config)
            NotificationCenter.default.post(name: NotificationName.Connected, object: self)
            
            // saving the config to a file. need to do an hack because there is no way to encode String:any with encode
            let jsonObject = try JSONSerialization.jsonObject(with: response.data!) as! [String:Any]
            let configData =  try JSONSerialization.data(withJSONObject: jsonObject["config"]!)
            try? configData.write(to: self.configURL)
          }
          catch let error {
            InnerLog.e("didn't succeed to decode \(error)")
            if let data = response.data {
              InnerLog.e("the info that was received" + String(data: data, encoding: String.Encoding.utf8)!)
            }
          }
          
        }
        else {
          InnerLog.e("the response not ok")
        }
      }
    }
  }
  
  func refreshToken (completionHandler:@escaping(Bool)->()) {
    if !Reachability.isConnectedToNetwork() {
      completionHandler(false)
      return
    }
    guard token != nil && appKey != nil else {
      InnerLog.e("the token or appKey are not initialized")
      return
    }
    let refresh = RefreshToken(token: token!, appKey: appKey!)
    isInLoginRequest = true
    self.token = nil
    ConnectionClient.shared.request(url: "auth/refreshSdkToken", data: refresh, method: HttpMethod.POST) { response in
      self.isInLoginRequest = false
      if response.ok {
        guard response.data != nil else {
          InnerLog.e("missing data")
          self.token = refresh.token; // there is an error the refresh token should be called again.
          completionHandler(false)
          return
        }
        let refreshResp = try? ConnectionClient.jsonDecoder.decode(RefreshTokenResponse.self, from: response.data!)
        self.token = refreshResp?.token
        completionHandler(true)
      }
      else {
        self.token = refresh.token; // there is an error the refresh token should be called again.
        completionHandler(false)
      }
    }
  }
}
#endif
