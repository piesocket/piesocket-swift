//
//  Channel.swift
//  basic-app
//
//  Created by Anand Singh on 18/11/22.
//
import Foundation
import Starscream

public class Channel{
    
    private static var NORMAL_CLOSURE_STATUS: UInt16 = 1000

    private var id: String
    private var ws: WebSocket?
    private var uuid: String
    
    private var listeners: [String: [String: (PieSocketEvent)->Void]]
    private var logger: Logger
    private var options: PieSocketOptions
    private var members: [AnyObject?]
    private var shouldReconnect: Bool

    
    
    public init(roomId: String, options: PieSocketOptions, logger: Logger){

        self.listeners = [String: [String: (PieSocketEvent)->Void]]()
        self.id = roomId
        self.logger = logger
        self.options = options
        self.uuid = UUID().uuidString
        self.shouldReconnect = false
        self.members = [AnyObject?]()
        
        try! self.connect()
    }
    
    public init(webSocketURL: String, enabledLogs: Bool){
        
        self.listeners = [String: [String: (PieSocketEvent)->Void]]()
        self.id = "standalone"
        self.logger = Logger(enabled: enabledLogs)
        self.options = PieSocketOptions()

        self.options.setWebSocketEndpoint(webSocketEndpoint: webSocketURL)

        self.uuid = UUID().uuidString
        self.shouldReconnect = false
        self.members = [AnyObject?]()

        try! self.connect()
    }
    
    private func isGuarded() -> Bool {
        if(self.options.getForceAuth()){
            return true;
        }

        return self.id.starts(with: "private-");
    }
    
    public func connect() throws{
        logger.log(text: "Connecting to: "+self.id);
        
        do{
            let endpoint: String = try buildEndpoint()
            
            logger.log(text: "WebSocket Endpoint: "+(endpoint));
        
            var request = URLRequest(url: URL(string: endpoint)!)
            request.timeoutInterval = 5
            ws = WebSocket(request: request)
            ws?.connect()
            ws?.onEvent = { event in
                switch event {
                    case .connected(_):
                        self.onOpen()
                    case .disconnected(let reason, let code):
                        self.onClosing()
                    case .text(let text):
                        self.onMessage(text: text)
                    case .cancelled:
                        self.onClosing()
                    case .error(let error):
                        self.onError(error: error!)
                    case .binary(_): break
                    case .pong(_): break
                    case .ping(_): break
                    case .viabilityChanged(_): break
                    case .reconnectSuggested(_): break
                    @unknown default:
                        break
                }
            }
        }catch PieSocketException.PausedForFetchingJwt{
            logger.log(text: "JWT not provided, will fetch from authEndpoint.")
        }catch PieSocketException.NeitherJwtNorAuthEndpointFound{
            throw PieSocketException.NeitherJwtNorAuthEndpointFound
        }


    }
    
    public func reconnect(){
        if(self.shouldReconnect){
            try! self.connect()
        }
    }
    
    public func listen(eventName: String, callback: @escaping (PieSocketEvent)->Void) -> String{
        var callbacks: [String: (PieSocketEvent)->Void];
        
        if(self.listeners.keys.contains(eventName)){
            callbacks = self.listeners[eventName]!
        }else{
            callbacks = [String: (PieSocketEvent)->Void]()
        }
        
        let callbackId: String = UUID().uuidString
        callbacks[callbackId] = callback

        listeners[eventName] = callbacks;
        
        return callbackId;
    }
    
    public func publish(event: PieSocketEvent){
        self.ws?.write(string: event.toString())
    }

    public func send(text: String){
        self.ws?.write(string: text)
    }

    
    public func removeListener(eventName: String, callbackId: String){
        
        if(self.listeners.keys.contains(eventName)){
            self.listeners[eventName]?.removeValue(forKey: callbackId);
        }
    }
    
    public func removeAllListeners(eventName: String){
        if(self.listeners.keys.contains(eventName)){
            self.listeners.removeValue(forKey: eventName)
        }
    }
    
    private func buildEndpoint() throws -> String{
        if(!self.options.getWebSocketEndpoint().isEmpty){
            return self.options.getWebSocketEndpoint()
        }
        
        let domain = self.options.getClusterDomain() ?? (self.options.getClusterId() + ".piesocket.com")
        let scheme = self.options.getSsl() ? "wss" : "ws"
        var endpoint: String = scheme + "://" + domain + "/v" + self.options.getVersion() + "/" + self.id + "?api_key=" + self.options.getApiKey() + "&notify_self=" + String(self.options.getNotifySelf()) + "&source=swiftskd&v=1&presence="+String(self.options.getPresence());
        
        //Append JWT
        let jwt: String = try getAuthToken()
        if(!jwt.isEmpty){
            endpoint = endpoint+"&jwt="+jwt
        }

        
        //Apend UserID
        let userId: String = options.getUserId()
        if(!userId.isEmpty){
            endpoint = endpoint+"&user="+userId
        }
        
        //Append UUID
        endpoint = endpoint + "&uuid=" + self.uuid
        
        return endpoint
    }
    
    private func getAuthToken() throws -> String {
        
        if(!options.getJwt().isEmpty){
            return options.getJwt()
        }
        
        if(self.isGuarded()){
            
            if(!self.options.getAuthEndpoint().isEmpty){
                getAuthTokenFromServer()
                throw PieSocketException.PausedForFetchingJwt
            }else{
                throw PieSocketException.NeitherJwtNorAuthEndpointFound
            }
        }
        return ""
    }
    
    private func getAuthTokenFromServer() {
            
      let parameters: [String: Any] = ["id": 13, "name": "jack"]
      let url = URL(string: self.options.getAuthEndpoint())! // change server url accordingly
      
      let session = URLSession.shared
      var request = URLRequest(url: url)
      request.httpMethod = "POST"

      //Add headers
      self.options.getAuthHeaders().forEach{ key, val in
         request.addValue(val , forHTTPHeaderField: key)
      }
      
      do {
        // convert parameters to Data and assign dictionary to httpBody of request
        request.httpBody = try JSONSerialization.data(withJSONObject: parameters, options: .prettyPrinted)
      } catch let error {
        print(error.localizedDescription)
        return
      }
      
      // create dataTask using the session object to send data to the server
      let task = session.dataTask(with: request) { data, response, error in
        
        if let error = error {
            self.logger.log(text: "Post Request Error: \(error.localizedDescription)")
          return
        }
    
        
        // ensure there is data returned
        guard let responseData = data else {
            self.logger.log(text: "nil Data received from the server")
          return
        }
        
        do {
          // create json object from data or use JSONDecoder to convert to Model stuct
          if let jsonResponse = try JSONSerialization.jsonObject(with: responseData, options: .mutableContainers) as? [String: Any] {
              
              let jwt: String = jsonResponse["auth"] as! String
              if(!jwt.isEmpty){
                  self.options.setJwt(jwt: jwt)
                  try! self.connect()
              }else{
                  self.logger.log(text: "No \"auth\" key found in JSON response from authEndpoint.")
              }
              
          } else {
            print("data maybe corrupted or in wrong format")
            throw URLError(.badServerResponse)
          }
        } catch let error {
          print(error.localizedDescription)
        }
      }
      // perform the task
      task.resume()
    }
        
    public func disconnect(){
        self.shouldReconnect = false
        self.ws?.disconnect(closeCode: Channel.NORMAL_CLOSURE_STATUS)
    }
    
    private func fireEvent(event: PieSocketEvent){
        logger.log(text: "Firing Event: " + event.getEvent());
        
        if(self.listeners.keys.contains(event.getEvent())){
            doFireEvents(listnerKey: event.getEvent(), event: event)
        }
        
        if(self.listeners.keys.contains("*")){
            doFireEvents(listnerKey: "*", event: event)
        }
    }

    public func doFireEvents(listnerKey: String, event: PieSocketEvent){
        let callbacks: [String: (PieSocketEvent)->Void] = self.listeners[listnerKey]!
        
        callbacks.forEach{ callbackId, callback in
            callback(event)
        }
    }

    public func getMemberByUUID(uuid: String) -> AnyObject?{
        var res: AnyObject?
        self.members.forEach{ member in
            if(member?["uuid"] as! String == uuid){
                res = member
            }
        }
        return res
    }
    
    public func getCurrentMember() -> AnyObject? {
        return self.getMemberByUUID(uuid: self.uuid);
    }

    public func getAllMembers() -> [AnyObject?]{
        return self.members
    }
    
    //WebSocket handlers
    private func onOpen(){

        let event: PieSocketEvent = PieSocketEvent(event: "system:connected");
        self.fireEvent(event: event);

        self.shouldReconnect = true;

    }
        
    private func onClosing(){
        let event: PieSocketEvent = PieSocketEvent(event: "system:closed");
        self.fireEvent(event: event);

        self.reconnect()
    }
    
    private func onError(error: any Error){
        let event: PieSocketEvent = PieSocketEvent(event: "system:error");
        self.fireEvent(event: event);
    }
    
    
    private func convertStringToDictionary(text: String) -> [String:AnyObject]? {
        if let data: Data = text.data(using: .utf8) {
           do {
               let json = try JSONSerialization.jsonObject(with: data, options: .mutableContainers) as? [String:AnyObject]
               return json
           } catch {
               return nil
           }
       }
       return nil
   }

    private func dictToString(dict: AnyObject?) -> String{
        do{
            let data: Data = try JSONSerialization.data(withJSONObject: dict as Any, options: .fragmentsAllowed)
            return String(data: data, encoding: .utf8) ?? ""
        }catch{
            return ""
        }
    }
    
    private func onMessage(text: String){
        
        var payload: PieSocketEvent = PieSocketEvent();
        
        if (self.listeners.keys.contains("system:message")) {
            payload.setEvent(event: "system:message");
            payload.setData(data: text);

            doFireEvents(listnerKey: "system:message", event: payload);
        }

        
        //Fire json events
        let jsonObject = convertStringToDictionary(text: text)
        
        if(jsonObject != nil){
            
            if(jsonObject?.keys.contains("event") ?? false ){
                payload.setEvent(event: jsonObject?["event"] as! String)
                payload.setData(data: dictToString(dict: jsonObject?["data"]));
                payload.setMeta(meta: dictToString(dict: jsonObject?["meta"]))

                //Trigger listener(s
                handleSystemEvents(event: payload)
                fireEvent(event: payload)
            }
            
            if(jsonObject?.keys.contains("error") ?? false ){
                self.shouldReconnect = false
                
                payload.setEvent(event: "system:error")
                payload.setData(data: dictToString(dict: jsonObject?["error"]))
                fireEvent(event: payload)
            }
            
            
        }
        
    }
    
    private func handleSystemEvents(event: PieSocketEvent){
        if(
            event.getEvent() == "system:member_list" ||
            event.getEvent() == "system:member_joined" ||
            event.getEvent() == "system:member_left"
        ){
            let object = convertStringToDictionary(text: event.getData())
            self.members = object?["members"] as! [AnyObject?]
        }
    }

}
