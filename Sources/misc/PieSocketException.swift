//
//  PieSocketException.swift
//  basic-app
//
//  Created by Anand Singh on 18/11/22.
//
import Foundation

public enum PieSocketException: Error {
    case ClusterIdNotSet
    case ApiKeyNotSet
    case NeitherJwtNorAuthEndpointFound
    case PausedForFetchingJwt
    /// v4: a control frame (subscribe/unsubscribe/get_members) failed or timed out.
    case ControlFrameFailed(String)
    /// v4: a raw binary send was attempted on a non-primary channel.
    case BinaryOnSecondaryChannel(String)
    /// v4: publish/send on a channel whose auth fetch is still in flight.
    case ChannelNotReady(String)
    case Generic(String)
}
