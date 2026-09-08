//
//  AuthResolver.swift
//
//  Resolves the JWT for a channel — the configured token, or one fetched from
//  the auth endpoint for guarded (`private-` / `forceAuth`) channels.
//
//  `Channel`'s own standalone `connect()` has an older, exception-based version
//  of this same resolution that predates this type and is left untouched. This
//  is the callback-based version used by v4's `Connection` — `PieSocket.join()`
//  must stay synchronous even while an auth fetch is in flight.
//
import Foundation

enum AuthResolver {

    static func isGuarded(_ channelId: String, _ options: PieSocketOptions) -> Bool {
        if options.getForceAuth() { return true }
        return channelId.hasPrefix("private-")
    }

    static func resolve(
        channelId: String,
        connectionUuid: String,
        options: PieSocketOptions,
        logger: Logger,
        onReady: @escaping (String?) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        if !options.getJwt().isEmpty {
            onReady(options.getJwt())
            return
        }

        if !isGuarded(channelId, options) {
            onReady(nil)
            return
        }

        if options.getAuthEndpoint().isEmpty {
            onError(PieSocketException.NeitherJwtNorAuthEndpointFound)
            return
        }

        logger.log(text: "Defer connection: fetching token from authEndpoint")
        fetchFromServer(
            channelId: channelId,
            connectionUuid: connectionUuid,
            options: options,
            logger: logger,
            onReady: onReady,
            onError: onError
        )
    }

    private static func fetchFromServer(
        channelId: String,
        connectionUuid: String,
        options: PieSocketOptions,
        logger: Logger,
        onReady: @escaping (String?) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        guard let url = URL(string: options.getAuthEndpoint()) else {
            onError(PieSocketException.Generic("Invalid authEndpoint URL"))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        options.getAuthHeaders().forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }

        let body: [String: Any] = [
            "channel_name": channelId,
            "connection_uuid": connectionUuid,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                onError(PieSocketException.Generic("Auth Token Server Error: \(error.localizedDescription)"))
                return
            }
            guard
                let data = data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let jwt = json["auth"] as? String,
                !jwt.isEmpty
            else {
                onError(PieSocketException.Generic("Auth endpoint did not return a token"))
                return
            }
            // Deliberately not persisted onto `options` — it is shared by every
            // channel on this PieSocket, and this token is scoped to `channelId`.
            logger.log(text: "Auth token fetched, resuming connection")
            onReady(jwt)
        }.resume()
    }
}
