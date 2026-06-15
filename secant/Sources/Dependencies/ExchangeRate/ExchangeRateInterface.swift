//
//  ExchangeRateInterface.swift
//  Zashi
//
//  Created by Lukáš Korba on 08-02-2024.
//

import ComposableArchitecture
@preconcurrency import Combine

@preconcurrency import ZcashLightClientKit

extension DependencyValues {
    var exchangeRate: ExchangeRateClient {
        get { self[ExchangeRateClient.self] }
        set { self[ExchangeRateClient.self] = newValue }
    }
}

@DependencyClient
struct ExchangeRateClient: Sendable {
    enum EchangeRateEvent: Equatable, Sendable {
        // Each event carries the currency the rate was fetched for, so consumers never have to
        // re-derive it (which would mislabel a rate when the selection changes mid-flight).
        case value(FiatCurrencyResult?, CurrencyISO4217)
        case refreshEnable(FiatCurrencyResult?, CurrencyISO4217)
        case stale(FiatCurrencyResult?, CurrencyISO4217)
    }
    
    enum RateSource: Equatable, Sendable {
        case coinMarketCap
        case sdk
    }

    var exchangeRateEventStream: @Sendable () -> AnyPublisher<EchangeRateEvent, Never> = { Empty().eraseToAnyPublisher() }
    var refreshExchangeRateUSD: @Sendable () -> Void = { }
    var selectedCurrency: @Sendable () -> CurrencyISO4217 = { .usd }
}
