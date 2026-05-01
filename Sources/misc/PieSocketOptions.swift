//
//  PieSocketOptions.swift
//  basic-app
//
//  Created by Anand Singh on 17/11/22.
//
import Foundation

public class PieSocketOptions{

    private var apiKey: String
    private var clusterId: String
    private var enableLogs: Bool
    private var notifySelf: Bool
    private var jwt: String
    private var presence: Bool
    private var authEndpoint: String
    private var authHeaders: [String: String]
    private var forceAuth: Bool
    private var userId: String
    private var version: String
    private var webSocketEndpoint: String
    private var clusterDomain: String?
    private var ssl: Bool

    public init(){
        apiKey = ""
        clusterId = ""
        enableLogs = true
        notifySelf = true
        jwt = ""
        presence = false
        authEndpoint = ""
        authHeaders = [String : String]()
        forceAuth = false
        userId = ""
        version = "3"
        webSocketEndpoint = ""
        clusterDomain = nil
        ssl = true
    }
    
    public func getApiKey() -> String {
        return apiKey
    }

    public func getClusterId() -> String {
        return clusterId
    }

    public func getEnableLogs() -> Bool {
        return enableLogs
    }

    public func getNotifySelf() -> Int {
        return notifySelf ? 1:0
    }

    public func getJwt() -> String {
        return jwt
    }

    public func getPresence() -> Int {
        return presence ? 1:0
    }

    public func getAuthEndpoint() -> String {
        return authEndpoint
    }

    public func getAuthHeaders() -> [String: String] {
        return authHeaders
    }

    public func getForceAuth() -> Bool {
        return forceAuth
    }

    public func getUserId() -> String {
        return userId
    }

    public func getVersion() -> String {
        return version
    }

    public func getWebSocketEndpoint() -> String {
        return webSocketEndpoint
    }

    public func getClusterDomain() -> String? {
        return clusterDomain
    }

    public func getSsl() -> Bool {
        return ssl
    }

    public func setApiKey(apiKey: String) {
        return self.apiKey = apiKey
    }

    public func setClusterId(clusterId: String) {
        return self.clusterId = clusterId
    }

    public func setEnableLogs(enableLogs: Bool) {
        return self.enableLogs = enableLogs
    }

    func setNotifySelf(notifySelf: Bool) {
        return self.notifySelf = notifySelf
    }

    public func setJwt(jwt: String){
        return self.jwt = jwt
    }

    public func setPresence(presence: Bool) {
        return self.presence = presence
    }

    public func setAuthEndpoint(authEndpoint: String) {
        return self.authEndpoint = authEndpoint
    }

    public func setAuthHeaders(authHeaders: [String: String]) {
        return self.authHeaders = authHeaders
    }

    public func setForceAuth(forceAuth: Bool) {
        return self.forceAuth = forceAuth
    }

    public func setUserId(userId: String) {
        return self.userId = userId
    }

    public func setVersion(version: String) {
        return self.version = version
    }

    func setWebSocketEndpoint(webSocketEndpoint: String) {
        return self.webSocketEndpoint = webSocketEndpoint
    }

    public func setClusterDomain(clusterDomain: String?) {
        self.clusterDomain = clusterDomain
    }

    public func setSsl(ssl: Bool) {
        self.ssl = ssl
    }

}
