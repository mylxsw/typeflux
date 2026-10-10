import Foundation

@MainActor
extension AuthState {
    // MARK: - Subscription

    var canUseCloudASR: Bool {
        !isLoadingSubscription
            && subscriptionError == nil
            && subscription.cloudASRAllowed
    }

    func refreshSubscriptionIfNeeded() {
        guard isLoggedIn || accessToken != nil else { return }
        Task { await refreshSubscription() }
    }

    @discardableResult
    func refreshSubscription() async -> BillingSubscriptionSnapshot? {
        guard let token = accessToken else {
            subscription = .none
            return nil
        }
        // Only a load for the current session is shared; one still running
        // for a replaced session must not keep the new session unloaded.
        let generation = sessionGeneration
        guard subscriptionLoadGeneration != generation else { return subscription }

        subscriptionLoadGeneration = generation
        isLoadingSubscription = true
        defer {
            if subscriptionLoadGeneration == generation {
                subscriptionLoadGeneration = nil
                isLoadingSubscription = false
            }
        }

        do {
            let snapshot = try await fetchSubscription(token)
            // A snapshot for a session that was logged out or replaced
            // meanwhile must not be shown for, or notify about, the new one.
            guard generation == sessionGeneration else { return nil }
            applySubscriptionSnapshot(snapshot)
            return snapshot
        } catch {
            guard generation == sessionGeneration else { return nil }
            subscriptionError = error.localizedDescription
            return nil
        }
    }

    /// Asks the server to reconcile the subscription and applies the result.
    /// Like `refreshSubscription`, a sync belongs to the session that started
    /// it: its snapshot or error is dropped when that session was logged out
    /// or replaced meanwhile, and the current session's subscription is
    /// returned instead.
    @discardableResult
    func syncSubscription() async throws -> BillingSubscriptionSnapshot {
        guard let token = accessToken else {
            throw AuthError.unauthorized
        }
        let generation = sessionGeneration
        guard subscriptionSyncGeneration != generation else { return subscription }

        subscriptionSyncGeneration = generation
        isSyncingSubscription = true
        defer {
            if subscriptionSyncGeneration == generation {
                subscriptionSyncGeneration = nil
                isSyncingSubscription = false
            }
        }

        let snapshot: BillingSubscriptionSnapshot
        do {
            snapshot = try await syncBillingSubscription(token)
        } catch {
            guard generation == sessionGeneration else { return subscription }
            throw error
        }
        guard generation == sessionGeneration else { return subscription }
        applySubscriptionSnapshot(snapshot)
        return snapshot
    }

    @discardableResult
    func refreshUsage() async -> CloudUsageStats? {
        guard let token = accessToken else {
            usageStats = .empty
            usageCredits = nil
            return nil
        }
        let generation = sessionGeneration
        guard usageLoadGeneration != generation else { return usageStats }

        usageLoadGeneration = generation
        isLoadingUsage = true
        defer {
            if usageLoadGeneration == generation {
                usageLoadGeneration = nil
                isLoadingUsage = false
            }
        }

        do {
            let snapshot = try await fetchCurrentPeriodUsageStats(token)
            // Usage of a session that was logged out or replaced meanwhile
            // must not be shown for the new one.
            guard generation == sessionGeneration else { return nil }
            usageStats = snapshot.stats
            usageCredits = snapshot.credits
            usagePeriodStart = snapshot.periodStart
            usagePeriodEnd = snapshot.periodEnd
            usageError = nil
            return snapshot.stats
        } catch let error as AuthError {
            guard generation == sessionGeneration else { return nil }
            if error.authErrorCode == "USAGE_PERIOD_UNAVAILABLE" {
                usageStats = .empty
                usageCredits = nil
                usagePeriodStart = nil
                usagePeriodEnd = nil
                usageError = nil
            } else {
                usageError = error.localizedDescription
            }
            return nil
        } catch {
            guard generation == sessionGeneration else { return nil }
            usageError = error.localizedDescription
            return nil
        }
    }

    /// Refreshes the subscription and the period's usage unless they were
    /// fetched within `maxAge` (the account card asks on every hover).
    func refreshAccountSummary(maxAge: TimeInterval = 60, now: Date = Date()) async {
        guard isLoggedIn else { return }
        if let last = lastAccountSummaryRefresh, now.timeIntervalSince(last) < maxAge { return }
        lastAccountSummaryRefresh = now
        await refreshTokenIfNeeded()
        await refreshSubscription()
        await refreshUsage()
    }

    /// Makes the next `refreshAccountSummary` fetch, e.g. after opening billing.
    func invalidateAccountSummary() {
        lastAccountSummaryRefresh = nil
    }

    /// Loads the per-day / per-feature credit breakdown. Failures (including a
    /// server that predates the endpoint) clear it so the charts hide quietly.
    @discardableResult
    func refreshUsageBreakdown(timeZone: TimeZone = .current) async -> CloudUsageBreakdown? {
        guard let token = accessToken else {
            usageBreakdown = nil
            return nil
        }
        let generation = sessionGeneration
        guard usageBreakdownLoadGeneration != generation else { return usageBreakdown }

        usageBreakdownLoadGeneration = generation
        isLoadingUsageBreakdown = true
        defer {
            if usageBreakdownLoadGeneration == generation {
                usageBreakdownLoadGeneration = nil
                isLoadingUsageBreakdown = false
            }
        }

        do {
            let breakdown = try await fetchCurrentPeriodUsageBreakdown(token, timeZone)
            guard generation == sessionGeneration else { return nil }
            usageBreakdown = breakdown
            return breakdown
        } catch is CancellationError {
            return usageBreakdown
        } catch {
            guard generation == sessionGeneration else { return nil }
            logger.info("Usage breakdown unavailable: \(error.localizedDescription, privacy: .public)")
            usageBreakdown = nil
            return nil
        }
    }

    func startCheckout(planCode: String = BillingPlan.defaultPlanCode) async throws -> URL {
        guard let token = accessToken else {
            throw AuthError.unauthorized
        }
        let generation = sessionGeneration
        let session = try await createCheckoutSession(token, planCode)
        try requireSession(generation)
        if !subscription.hasPaidSubscription {
            pendingCheckoutSubscriptionEntitlement = true
        }
        startCheckoutPolling()
        return session.url
    }

    func createBillingPortalSession() async throws -> URL {
        guard let token = accessToken else {
            throw AuthError.unauthorized
        }
        let generation = sessionGeneration
        let session = try await createPortalSession(token)
        try requireSession(generation)
        return session.url
    }

    func requestBillingPageToken() async throws -> URL {
        guard let token = accessToken else {
            throw AuthError.unauthorized
        }
        let generation = sessionGeneration
        let response = try await issueBillingPageToken(token)
        try requireSession(generation)
        return response.plansURL
    }

    /// The billing page opened on `tab`, e.g. `BillingPlansLink.creditsTab`.
    func requestBillingPageToken(tab: String?) async throws -> URL {
        try await BillingPlansLink.url(requestBillingPageToken(), tab: tab)
    }

    /// A billing link is signed for the account that requested it. One that
    /// arrives after that session was logged out or replaced must not be
    /// opened (or start checkout polling) for whoever is signed in now.
    private func requireSession(_ generation: Int) throws {
        guard generation == sessionGeneration else {
            logger.info("Discarding billing link for a replaced session")
            throw AuthError.unauthorized
        }
    }

    private func startCheckoutPolling() {
        checkoutPollingTask?.cancel()
        checkoutPollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for attempt in 0 ..< Self.checkoutPollingAttempts {
                if attempt > 0 {
                    try? await Task.sleep(for: Self.checkoutPollingInterval)
                }
                guard !Task.isCancelled else { return }
                _ = await refreshSubscription()
                if subscription.hasPaidSubscription {
                    return
                }
            }
            pendingCheckoutSubscriptionEntitlement = false
        }
    }

    private func applySubscriptionSnapshot(_ snapshot: BillingSubscriptionSnapshot) {
        let wasEntitled = subscription.entitled
        let hadPaidSubscription = subscription.hasPaidSubscription
        let subscriptionChanged = subscription != snapshot
        subscription = snapshot
        subscriptionError = nil
        if subscriptionChanged {
            NotificationCenter.default.post(name: .authSubscriptionDidChange, object: self)
        }
        let becameEntitled = !wasEntitled && snapshot.entitled
        let becamePaid = !hadPaidSubscription && snapshot.hasPaidSubscription
        if pendingCheckoutSubscriptionEntitlement, becameEntitled || becamePaid {
            pendingCheckoutSubscriptionEntitlement = false
            NotificationCenter.default.post(name: .authCheckoutSubscriptionDidBecomeEntitled, object: self)
        }
    }
}
