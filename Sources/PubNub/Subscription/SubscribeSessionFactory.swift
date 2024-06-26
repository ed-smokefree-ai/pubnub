//
//  SubscribeSessionFactory.swift
//
//  Copyright (c) PubNub Inc.
//  All rights reserved.
//
//  This source code is licensed under the license found in the
//  LICENSE file in the root directory of this source tree.
//

import Foundation

/// A factory that manages instances of `SubscriptionSession`
///
/// This factory attempts to ensure that regardless of how many `PubNub`
/// instances you will only create a single `SubscriptionSession`.
///
///  You should only use one instance of a `SubscriptionSession` unless you have a very specialized workflow.
///  Such as one of the following:
/// * Subscribe using multiple sets of subscribe keys
/// * Need separate network configurations on a per channel/group basis
///
/// - Important: Having multiple `SubscriptionSession` instances will result in
/// increase network usage and battery drain.
@available(*, deprecated, message: "Use methods from a PubNub object to subscribe/unsubscribe")
public class SubscribeSessionFactory {
  private typealias SessionMap = [Int: WeakBox<SubscriptionSession>]

  /// The singleton instance for this factory
  public let subscribeQueue = DispatchQueue(label: "Subscribe Response Queue")
  public static var shared = SubscribeSessionFactory()
  private let sessions = Atomic<SessionMap>([:])
  private init() {}

  /// Retrieve a session matching the hash value of the configuration or creates a new one if no match was found
  ///
  /// The `session` parameter will only be injected into the `SubscriptionSession` in the event
  /// that a new `SubscriptionSession` is created
  ///
  /// - Parameters:
  ///   - from: A configuration that will be used to fetch an existing SubscriptionSession or create a new one
  ///   - with: `SessionReplaceable` that will be used as the underlying `Session`
  /// - Returns: A `SubscriptionSession` that can be used to make PubNub subscribe and presence API calls with
  public func getSession(
    from config: SubscriptionConfiguration,
    with subscribeSession: SessionReplaceable? = nil,
    presenceSession: SessionReplaceable? = nil
  ) -> SubscriptionSession {
    // The hash value for the given configuration
    let configHash = config.subscriptionHashValue
    // Returns a session (if any) that matches the hash value
    if let session = sessions.lockedRead({ $0[configHash]?.underlying }) {
      PubNub.log.debug("Found existing session for config hash \(config.subscriptionHashValue)")
      return session
    }
    
    PubNub.log.debug("Creating new session for with hash value \(config.subscriptionHashValue)")
    
    return sessions.lockedWrite { dictionary in
      let subscriptionSession = SubscriptionSession(
        strategy: resolveStrategy(
          configuration: config,
          subscribeSession: subscribeSession,
          presenceSession: presenceSession
        )
      )
      dictionary.updateValue(
        WeakBox(subscriptionSession),
        forKey: configHash
      )
      return subscriptionSession
    }
    
    func resolveStrategy(
      configuration: SubscriptionConfiguration,
      subscribeSession: SessionReplaceable?,
      presenceSession: SessionReplaceable?
    ) -> any SubscriptionSessionStrategy {
      // Creates default network session objects if they're not provided
      let subscribeSession = subscribeSession ?? HTTPSession(
        configuration: URLSessionConfiguration.subscription,
        sessionQueue: subscribeQueue,
        sessionStream: SessionListener(queue: subscribeQueue)
      )
      let presenceSession = presenceSession ?? HTTPSession(
        configuration: URLSessionConfiguration.pubnub,
        sessionQueue: subscribeQueue,
        sessionStream: SessionListener(queue: subscribeQueue)
      )
      
      if let config = config as? PubNubConfiguration, config.enableEventEngine {
        let subscribeEffectFactory = SubscribeEffectFactory(
          session: subscribeSession,
          presenceStateContainer: .shared
        )
        let subscribeEngine = EventEngineFactory().subscribeEngine(
          with: config,
          dispatcher: EffectDispatcher(factory: subscribeEffectFactory),
          transition: SubscribeTransition()
        )
        let presenceEffectFactory = PresenceEffectFactory(
          session: presenceSession,
          presenceStateContainer: .shared
        )
        let presenceEngine = EventEngineFactory().presenceEngine(
          with: config,
          dispatcher: EffectDispatcher(factory: presenceEffectFactory),
          transition: PresenceTransition(configuration: config)
        )
        return EventEngineSubscriptionSessionStrategy(
          configuration: config,
          subscribeEngine: subscribeEngine,
          presenceEngine: presenceEngine,
          presenceStateContainer: .shared
        )
      }
      
      return LegacySubscriptionSessionStrategy(
        configuration: configuration,
        network: subscribeSession,
        presenceSession: presenceSession
      )
    }
  }

  /// Clean-up method that can be used to poke each weakbox to see if its nil
  func sessionDestroyed() {
    sessions.lockedWrite { sessionMap in
      sessionMap.keys.forEach { if sessionMap[$0]?.underlying == nil { sessionMap.removeValue(forKey: $0) } }
    }
  }
}

// MARK: - SubscriptionConfiguration

/// The configuration used to determine the uniqueness of a `SubscriptionSession`
@available(*, deprecated, message: "Use a PubNub object with PubNubConfiguration that matches the parameters below")
public protocol SubscriptionConfiguration: RouterConfiguration {
  /// Reconnection policy which will be used if/when a request fails
  var automaticRetry: AutomaticRetry? { get }
  /// How long (in seconds) the server will consider the client alive for presence
  ///
  /// - NOTE: The minimum value this field can be is 20
  var durationUntilTimeout: UInt { get }
  /// How often (in seconds) the client will announce itself to server
  ///
  /// - NOTE: The minimum value this field can be is 0
  var heartbeatInterval: UInt { get }
  /// Whether to send out the leave requests
  var supressLeaveEvents: Bool { get }
  /// The number of messages into the payload before emitting `RequestMessageCountExceeded`
  var requestMessageCountThreshold: UInt { get }
  /// PSV2 feature to subscribe with a custom filter expression.
  var filterExpression: String? { get }
  /// If Access Manager (PAM) is enabled, client will use  `authToken` instead of `authKey` on all requests
  override var authToken: String? { get set }
}

extension SubscriptionConfiguration {
  /// The hash value.
  ///
  /// Hash values are not guaranteed to be equal across different executions of your program.
  /// Do not save hash values to use during a future execution.
  var subscriptionHashValue: Int {
    var hasher = Hasher()
    hasher.combine(durationUntilTimeout.hashValue)
    hasher.combine(heartbeatInterval.hashValue)
    hasher.combine(supressLeaveEvents.hashValue)
    hasher.combine(requestMessageCountThreshold.hashValue)
    hasher.combine(filterExpression.hashValue)
    hasher.combine(subscribeKey.hashValue)
    hasher.combine(uuid.hashValue)
    hasher.combine(useSecureConnections.hashValue)
    hasher.combine(origin.hashValue)
    hasher.combine(authKey.hashValue)
    hasher.combine(cryptoModule.hashValue)
    return hasher.finalize()
  }
}

extension PubNubConfiguration: SubscriptionConfiguration {}
